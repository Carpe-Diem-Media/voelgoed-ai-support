import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { createInterface } from "node:readline";

const npmRoot = execFileSync("npm", ["root", "-g"], { encoding: "utf8" }).trim();
const require = createRequire(resolve(npmRoot, "vgas-proof.cjs"));
const puppeteer = require("puppeteer-core");
const input = createInterface({ input: process.stdin });
const [line] = await readLine();
const cookies = JSON.parse(line);
const target = "https://staff.example.test";
const output = process.env.VGAS29_BROWSER_ARTIFACTS;
assert.ok(output);
await mkdir(output, { recursive: true, mode: 0o700 });

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || "/opt/google/chrome/chrome",
  headless: true,
  acceptInsecureCerts: true,
  args: [
    "--no-proxy-server",
    "--host-resolver-rules=MAP staff.example.test 127.0.0.1:4204",
    "--disable-background-networking",
  ],
});

let stage = "launch";
try {
  for (const role of ["operator", "admin"]) {
    stage = role + " admission";
    const context = await browser.createBrowserContext();
    await context.setCookie({
      name: "_vgas_staff",
      value: cookies[role],
      domain: "staff.example.test",
      path: "/staff",
      secure: true,
      httpOnly: true,
    });
    const page = await context.newPage();
    const session = await page.createCDPSession();
    await session.send("Network.enable");
    let upgraded = false;
    session.on("Network.webSocketHandshakeResponseReceived", ({ response }) => {
      upgraded ||= response.status === 101;
    });
    const status = await page.goto(target + "/staff/operations");
    assert.equal(status.status(), 200);
    await page.waitForSelector(".phx-connected", { timeout: 5_000 });
    assert.ok(upgraded);
    assert.equal(await page.$eval("h1", (node) => node.textContent.trim()), "Support operations");

    if (role === "operator") {
      stage = "operator role and keyboard";
      assert.ok(!(await page.content()).includes("Disable automation"));
      await page.keyboard.press("Tab");
      assert.equal(await page.evaluate(() => document.activeElement.textContent.trim()), "Skip to content");
      await page.keyboard.press("Enter");
      assert.equal(await page.evaluate(() => document.activeElement.id), "main");

      await page.focus("a[href^='/staff/operations/']");
      assert.equal(await page.evaluate(() => getComputedStyle(document.activeElement).outlineStyle), "solid");
      await page.keyboard.press("Enter");
      await page.waitForSelector("#session-detail button:not([disabled])", { timeout: 5_000 });

      stage = "operator widths and reduced motion";
      await page.emulateMediaFeatures([{ name: "prefers-reduced-motion", value: "reduce" }]);
      for (const width of [320, 375, 1440]) {
        await page.setViewport({ width, height: 900 });
        assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
        assert.equal(await page.evaluate(() => matchMedia("(prefers-reduced-motion: reduce)").matches), true);
        await page.screenshot({ path: resolve(output, `operator-${width}.png`), fullPage: true });
      }
    } else {
      stage = "admin scope";
      const html = await page.content();
      assert.ok(html.includes("Disable automation"));
      assert.ok(!html.includes("Support queue"));
      await page.setViewport({ width: 1440, height: 900 });
      await page.screenshot({ path: resolve(output, "admin-1440.png"), fullPage: true });
    }

    stage = role + " sanitized capture";
    const html = await page.evaluate(() => {
      const doc = document.documentElement.cloneNode(true);
      doc.querySelectorAll("script, meta[name=csrf-token]").forEach((el) => el.remove());
      doc.querySelectorAll("*").forEach((el) => {
        for (const name of el.getAttributeNames()) {
          if (name.startsWith("data-phx-") || name.startsWith("phx-")) el.removeAttribute(name);
        }
      });
      for (const link of doc.querySelectorAll("link[rel=stylesheet]")) {
        link.href = link.href.split("/").at(-1);
      }
      return "<!doctype html>\n" + doc.outerHTML;
    });

    assert.ok(!html.includes("_vgas_staff"));
    assert.ok(!html.includes("data-phx-session"));
    await writeFile(resolve(output, `${role}.html`), html);
    await context.close();
  }

  stage = "anonymous denial";
  const page = await browser.newPage();
  const denied = await page.goto(target + "/staff/operations");
  assert.equal(denied.status(), 401);
  assert.ok((await page.content()).includes("Staff access denied"));
  await page.screenshot({ path: resolve(output, "denied.png") });
  console.log("Authenticated WebSocket, role isolation, keyboard focus, three widths, reduced motion and denial passed.");
} catch {
  console.error("Browser proof failed at " + stage);
  process.exitCode = 1;
} finally {
  await browser.close();
}

async function readLine() {
  for await (const value of input) {
    input.close();
    return [value];
  }
  throw new Error("Missing fixture input");
}
