// Checks the Markdown sources (README.md and docs/*.md) before they are built.
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { parseAllDocuments } from "yaml";
import { DOCS_DIR, REPO_DIR, markdownHeadings } from "./docs.mjs";

/** Every ```yaml block must load, so that it can be copied into a `.outskirts.yml` as is. */
export function yamlBlockErrors(file, source) {
  const errors = [];
  for (const m of source.matchAll(/^```ya?ml[^\n]*\n([\s\S]*?)^```/gm)) {
    const line = source.slice(0, m.index).split("\n").length;
    for (const doc of parseAllDocuments(m[1])) {
      for (const error of doc.errors) errors.push(`${file}:${line}: invalid YAML block: ${error.message.split("\n")[0]}`);
    }
  }
  return errors;
}

/** Ids a Markdown file defines: its heading slugs and explicit `id="…"` / `name="…"` attributes. */
export function markdownIds(source) {
  const ids = new Set(markdownHeadings(source).map((h) => h.slug));
  for (const m of source.matchAll(/\s(?:id|name)="([^"]+)"/g)) ids.add(m[1]);
  return ids;
}

/** Links `#anchor`, `other.md#anchor` and `https://outskirts.dev/docs/page/#anchor` must reach an existing section. */
export function anchorErrors(file, source, idsOf) {
  const errors = [];
  const text = source.replace(/^(`{3,}|~{3,})[\s\S]*?^\1/gm, "").replace(/`[^`\n]*`/g, "");
  for (const m of text.matchAll(/\]\(([^)\s]*#[^)\s]+)\)|\shref="([^"]*#[^"]+)"/g)) {
    let href = m[1] ?? m[2];
    const site = href.match(/^https:\/\/outskirts\.dev\/docs\/([a-z-]*)\/?#/);
    if (site) {
      if (site[1] === "changelog") continue;
      href = `${site[1] || "README"}.md#${href.split("#")[1]}`;
      if (!file.startsWith("docs/")) href = `docs/${href}`;
    } else if (/^[a-z]+:/.test(href)) continue;
    const [path, anchor] = href.split("#");
    if (path && !path.endsWith(".md")) continue;
    const target = path ? join(file, "..", path) : file;
    const ids = idsOf(target);
    if (!ids) errors.push(`${file}: link to ${href}, but ${target} does not exist`);
    else if (!ids.has(decodeURIComponent(anchor))) errors.push(`${file}: link to ${href}, which has no such section`);
  }
  return errors;
}

/** Runs both checks on README.md and docs/*.md. */
export function checkMarkdownSources() {
  const files = ["README.md", ...readdirSync(DOCS_DIR).filter((f) => f.endsWith(".md")).sort().map((f) => `docs/${f}`)];
  const sources = new Map(files.map((f) => [f, readFileSync(join(REPO_DIR, f), "utf8")]));
  const cache = new Map();
  const idsOf = (f) => {
    if (!cache.has(f)) cache.set(f, sources.has(f) ? markdownIds(sources.get(f)) : null);
    return cache.get(f);
  };
  return [...sources].flatMap(([f, s]) => [...yamlBlockErrors(f, s), ...anchorErrors(f, s, idsOf)]);
}
