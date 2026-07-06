// Persistent Playwright bridge used by test/_support/playwright.ex.
const net = require("net");
const { chromium, firefox } = require("playwright");

const browserTypes = { chromium, firefox };
const browsers = new Map();

async function launchBrowsers(browserNames) {
  for (const browserName of browserNames) {
    if (!browserTypes[browserName]) {
      throw new Error(`Unsupported browser ${JSON.stringify(browserName)}`);
    }

    const options =
      browserName === "chromium"
        ? { args: ["--no-sandbox", "--disable-setuid-sandbox"] }
        : {};

    browsers.set(browserName, await browserTypes[browserName].launch(options));
  }
}

async function runScript(payload) {
  const { browser: browserName, script, context = {} } = payload;
  const browser = browsers.get(browserName);

  if (!browser) {
    throw new Error(
      `Unsupported browser ${JSON.stringify(browserName)}; expected chromium or firefox`,
    );
  }

  const browserContext = await browser.newContext();
  const page = await browserContext.newPage();

  try {
    const fn = new Function(
      "page",
      "context",
      `
        return (async () => {
          ${script}
        })();
      `,
    );

    const data = await fn(page, context);
    return { success: true, data };
  } catch (error) {
    return {
      success: false,
      error: error.message,
      stack: error.stack,
    };
  } finally {
    await browserContext.close();
  }
}

function writeResponse(socket, response) {
  const json = JSON.stringify(response);
  const length = Buffer.byteLength(json, "utf8").toString().padStart(8, "0");
  socket.write(length + json);
}

function serveConnection(socket) {
  let buffer = Buffer.alloc(0);

  socket.on("data", async (data) => {
    buffer = Buffer.concat([buffer, data]);

    while (buffer.length >= 8) {
      const length = Number.parseInt(buffer.subarray(0, 8).toString("ascii"), 10);

      if (!Number.isSafeInteger(length) || length <= 0) {
        buffer = Buffer.alloc(0);
        writeResponse(socket, {
          success: false,
          error: "Invalid message length",
        });
        return;
      }

      if (buffer.length < 8 + length) return;

      const json = buffer.subarray(8, 8 + length).toString("utf8");
      buffer = buffer.subarray(8 + length);

      try {
        writeResponse(socket, await runScript(JSON.parse(json)));
      } catch (error) {
        writeResponse(socket, {
          success: false,
          error: error.message,
          stack: error.stack,
        });
      }
    }
  });
}

async function shutdown(server) {
  server.close();
  await Promise.all([...browsers.values()].map((browser) => browser.close()));
  process.exit(0);
}

async function startServer(port, browserNames) {
  await launchBrowsers(browserNames);

  const server = net.createServer(serveConnection);
  server.listen(port, "127.0.0.1", () => {
    console.log(`Playwright server listening on port ${port}`);
  });

  process.on("SIGTERM", () => shutdown(server));
  process.on("SIGINT", () => shutdown(server));
}

const port = Number.parseInt(process.argv[2], 10) || 4456;
const browserNames = (process.argv[3] || "chromium,firefox").split(",");

startServer(port, browserNames).catch((error) => {
  console.error(error);
  process.exit(1);
});
