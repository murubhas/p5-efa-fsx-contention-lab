#!/usr/bin/env node

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const execFileAsync = promisify(execFile);
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PAGE = path.resolve(
  __dirname,
  "..",
  "docs",
  "p5-efa-fsx-contention-animation.html",
);
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const SIZES = [
  [1920, 1080],
  [1600, 900],
  [1366, 768],
  [1280, 720],
];

const PROBE = String.raw`
(function () {
  function output(value) {
    document.documentElement.setAttribute(
      "data-efa-verify",
      encodeURIComponent(JSON.stringify(value))
    );
  }
  function run() {
    var verificationStyle = document.createElement("style");
    verificationStyle.textContent = "*{transition:none!important}";
    document.head.appendChild(verificationStyle);

    var duplicateIds = [];
    var seen = {};
    document.querySelectorAll("[id]").forEach(function (element) {
      if (seen[element.id]) duplicateIds.push(element.id);
      seen[element.id] = true;
    });

    var unnamed = [];
    document.querySelectorAll("button,a[href]").forEach(function (element) {
      var name = (element.getAttribute("aria-label") || element.textContent || "").trim();
      if (!name) unnamed.push(element.tagName + "#" + (element.id || "?"));
    });

    var external = [];
    document.querySelectorAll("script[src],link[href],img[src]").forEach(function (element) {
      var value = element.getAttribute("src") || element.getAttribute("href") || "";
      if (/^https?:|^\/\//.test(value)) external.push(value);
    });

    var phaseStates = [];
    window.__efaStory.pause();
    for (var phase = 0; phase < window.__efaStory.phaseCount; phase += 1) {
      window.__efaStory.setPhase(phase, false);
      phaseStates.push({
        phase: document.body.dataset.phase,
        current: document.querySelectorAll('[aria-current="step"]').length,
        ncclOpacity: getComputedStyle(document.querySelector(".nccl-path")).opacity,
        storageOpacity: getComputedStyle(document.querySelector(".storage-path")).opacity,
        title: document.getElementById("phaseTitle").textContent.trim(),
      });
    }

    var shell = document.querySelector(".shell");
    var visual = document.querySelector(".visual");
    output({
      phaseCount: window.__efaStory.phaseCount,
      phaseStates: phaseStates,
      duplicateIds: duplicateIds,
      unnamed: unnamed,
      external: external,
      bodyOverflowX: document.documentElement.scrollWidth - innerWidth,
      bodyOverflowY: document.documentElement.scrollHeight - innerHeight,
      shellBottom: Math.round(shell.getBoundingClientRect().bottom),
      visualWidth: Math.round(visual.getBoundingClientRect().width),
      visualHeight: Math.round(visual.getBoundingClientRect().height),
      reduced: document.documentElement.dataset.reduced,
      playing: window.__efaStory.isPlaying(),
    });
  }
  if (document.readyState === "complete") setTimeout(run, 450);
  else addEventListener("load", function () { setTimeout(run, 450); });
})();
`;

async function probe(width, height, reduced = false) {
  const source = await fs.readFile(PAGE, "utf8");
  const injected = source.replace("</body>", `<script>${PROBE}</script></body>`);
  const temporary = path.join(
    os.tmpdir(),
    `efa-fsx-animation-${width}x${height}-${reduced ? "reduced" : "full"}.html`,
  );
  await fs.writeFile(temporary, injected, "utf8");

  const args = [
    "--headless",
    "--disable-gpu",
    "--no-sandbox",
    "--hide-scrollbars",
    "--allow-file-access-from-files",
    "--enable-logging=stderr",
    "--v=0",
    "--virtual-time-budget=3000",
    `--window-size=${width},${height}`,
    "--dump-dom",
  ];
  if (reduced) args.push("--force-prefers-reduced-motion=reduce");
  args.push(`file://${temporary}`);

  let combined = "";
  try {
    const result = await execFileAsync(CHROME, args, {
      maxBuffer: 32 * 1024 * 1024,
    });
    combined = `${result.stdout || ""}\n${result.stderr || ""}`;
  } catch (error) {
    combined = `${error.stdout || ""}\n${error.stderr || ""}`;
  }
  await fs.rm(temporary, { force: true });

  const marker = combined.match(/data-efa-verify="([^"]+)"/);
  if (!marker) {
    throw new Error(
      `Could not parse browser probe at ${width}x${height}:\n${combined.slice(-2200)}`,
    );
  }
  return JSON.parse(decodeURIComponent(marker[1].replace(/&amp;/g, "&")));
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const pageStat = await fs.stat(PAGE);
assert(pageStat.size > 20_000, "Animation page appears unexpectedly small");

for (const [width, height] of SIZES) {
  const result = await probe(width, height);
  assert(result.phaseCount === 5, `${width}x${height}: expected five phases`);
  assert(result.duplicateIds.length === 0, `${width}x${height}: duplicate ids`);
  assert(result.unnamed.length === 0, `${width}x${height}: unnamed controls`);
  assert(result.external.length === 0, `${width}x${height}: external dependencies`);
  assert(result.bodyOverflowX <= 1, `${width}x${height}: horizontal overflow`);
  assert(result.bodyOverflowY <= 1, `${width}x${height}: vertical overflow`);
  assert(result.visualWidth > 900, `${width}x${height}: visual collapsed`);
  assert(result.visualHeight >= 310, `${width}x${height}: visual too short`);
  assert(
    result.phaseStates.every((state, index) => state.phase === String(index)),
    `${width}x${height}: phase state mismatch`,
  );
  assert(
    result.phaseStates.every((state) => state.current === 1),
    `${width}x${height}: active phase control mismatch`,
  );
  assert(result.phaseStates[1].ncclOpacity === "1", `${width}x${height}: NCCL phase inactive`);
  assert(result.phaseStates[2].storageOpacity === "1", `${width}x${height}: storage phase inactive`);
  assert(
    result.phaseStates[3].ncclOpacity === "1" && result.phaseStates[3].storageOpacity === "1",
    `${width}x${height}: overlap phase incomplete`,
  );
  console.log(
    `PASS ${width}x${height} visual=${result.visualWidth}x${result.visualHeight} ` +
    `overflowY=${result.bodyOverflowY}`,
  );
}

const reducedResult = await probe(1280, 720, true);
assert(reducedResult.reduced === "true", "Reduced-motion preference was not detected");
assert(reducedResult.playing === false, "Reduced-motion mode should not autoplay");
console.log("PASS reduced-motion mode");
console.log(`VERIFIED ${PAGE}`);
