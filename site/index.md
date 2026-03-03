# qip

## _Vibe once, run anywhere_

`qip` lets you compose vibe-coded WebAssembly modules that process text/image/data in a secure pipeline.

Each module does one focused job: parser, validator, shader, converter, renderer, and so on. You then compose modules into ever greater units using the built-in web router or into a image effect pipeline.

Think of them as “React components for everything that run everywhere.”

## Install

```bash
go install github.com/royalicing/qip@latest
```

## Text

TODO: add word count example.

## Images

TODO: add image processing pipeline.

## SVG icons

```bash
curl https://unpkg.com/lucide-static@0.575.0/icons/cog.svg \
| qip run modules/image/svg+xml/svg-recolor-current-color.wasm '?color_rgba=0xff7722ff' \
modules/image/svg+xml/svg-rasterize.wasm \
modules/bytes/bmp-to-ico.wasm \
> cog.ico
```

<form>
    <qip-preview>
        <source src="/modules/image/svg+xml/svg-recolor-current-color.wasm" type="application/wasm" data-uniform-color_rgba="0xff7722ff" />
        <source src="/modules/image/svg+xml/svg-rasterize.wasm" type="application/wasm" />
        <source src="/modules/bytes/bmp-to-ico.wasm" type="application/wasm" />
        <textarea name="input" rows="20" cols="40">&lt;svg
  class=&quot;lucide lucide-cog&quot;
  xmlns=&quot;http://www.w3.org/2000/svg&quot;
  width=&quot;24&quot;
  height=&quot;24&quot;
  viewBox=&quot;0 0 24 24&quot;
  fill=&quot;none&quot;
  stroke=&quot;currentColor&quot;
  stroke-width=&quot;2&quot;
  stroke-linecap=&quot;round&quot;
  stroke-linejoin=&quot;round&quot;
&gt;
  &lt;path d=&quot;M11 10.27 7 3.34&quot; /&gt;
  &lt;path d=&quot;m11 13.73-4 6.93&quot; /&gt;
  &lt;path d=&quot;M12 22v-2&quot; /&gt;
  &lt;path d=&quot;M12 2v2&quot; /&gt;
  &lt;path d=&quot;M14 12h8&quot; /&gt;
  &lt;path d=&quot;m17 20.66-1-1.73&quot; /&gt;
  &lt;path d=&quot;m17 3.34-1 1.73&quot; /&gt;
  &lt;path d=&quot;M2 12h2&quot; /&gt;
  &lt;path d=&quot;m20.66 17-1.73-1&quot; /&gt;
  &lt;path d=&quot;m20.66 7-1.73 1&quot; /&gt;
  &lt;path d=&quot;m3.34 17 1.73-1&quot; /&gt;
  &lt;path d=&quot;m3.34 7 1.73 1&quot; /&gt;
  &lt;circle cx=&quot;12&quot; cy=&quot;12&quot; r=&quot;2&quot; /&gt;
  &lt;circle cx=&quot;12&quot; cy=&quot;12&quot; r=&quot;8&quot; /&gt;
&lt;/svg&gt;</textarea>
        <output name="output"></output>
    </qip-preview>
</form>

## Markdown

<form>
    <qip-preview>
        <source src="/modules/text/markdown/commonmark.0.31.2.wasm" type="application/wasm" />
        <textarea name="input" rows="10" cols="40"># Write some *Markdown*
&#10;Here’s a [link](https&colon;//example.com)
</textarea>
<output name="output"></output>
</qip-preview>

</form>

How to replicate a full CommonMark implementation workflow with `qip`:

1. Download the CommonMark spec source text (pin a version for reproducibility).
2. Ask a coding agent (for example, Codex or Claude Code) to generate a compliance module wasm from the spec using `qip comply`.
3. Ask a coding agent to implement a new markdown wasm from scratch (for example `modules/text/markdown/commonmark.0.31.2.zig`) and iterate until compliance passes.

```bash
# 1) Download spec text (pin the tag/version you want)
curl -L https://raw.githubusercontent.com/commonmark/commonmark-spec/0.31.2/spec.txt \
  -o compliance/commonmark-spec-0.31.2.txt

# 2) Build your markdown implementation wasm (example path)
make -B -j modules/text/markdown/commonmark.0.31.2.wasm

# 3) Run compliance and keep iterating until PASS
./qip comply modules/text/markdown/commonmark.0.31.2.wasm \
  --with compliance/commonmark-spec-0.31.2.wasm
```

Agent prompt pattern that works well:

- “Create `compliance/commonmark-spec-0.31.2.wasm` from `spec.txt` using qip comply conventions.”
- “Now implement `modules/text/markdown/commonmark.0.31.2.wasm` from scratch and keep running `qip comply ... --with compliance/commonmark-spec-0.31.2.wasm` until it passes.”

## Websites

TODO: show how to combine all of this into a website.

## Vibe once, run everywhere

TODO: explain why we’d want to invest into a particular implementation and run that everywhere.

## The problems with software today

Software today is like Matryoshka dolls, frameworks that depend on libraries that depend on libraries that depend on OS libs and so on. This can be incredibly productive for building, but has lead to increasingly complex and bloated end-user apps.

This has expanded the surface areas for security attacks, due to the large number of moving parts and countless dependencies prone to supply-chain attacks. It also means that software is less predictable and harder to debug. Any line of a dependency could be reading SSH keys & secrets, mining bitcoin, remotely executing code. This gets worse in an AI world, especially if we are no longer closely reviewing code.

## Two key technologies combined

There are two recent technologies that change this: WebAssembly and agentic coding.

With WebAssembly we get light cross-platform executables. We can really write once, run anywhere. We can create stable, self-contained binaries that don’t depend on anything external. We can sandbox them so they don’t have any access to the outside world: no file system, no network, not even the current time. This makes them deterministic, a property that makes software more predictable, reliable, and easy to test.

## AI needs hard boundaries

With agentic coding we get the ability to quickly mass produce software. But most programming languages today have wide capabilities that make untrustworthy code risky. Any generated line could read SSH keys or talk to the network or mine bitcoin. We need hard constraints.

Coding agents are now good enough that you can vibe C or Zig modules that run super fast, as long as there are clear boundaries.

`qip` forces you to break code into boundaries. Most modules follow a simple contract: there’s some input provided to the WebAssembly module, and there’s some output it produces. Since this contract is deterministic we can then cache easily using the input as a key. Since modules are self-contained and immutable we can also use them as a cache key. Connect these modules together and you get a deterministic pipeline. Weave these pipelines together and you get a predictable, understandable system.

## Old guardrails

Paradigms like functional or object-oriented or garbage collection become less relevant in this new world. These were patterns that allowed teams of humans to consistently make sense of the modular parts they wove into software. To a LLM, imperative is just as easy as any other paradigm to author. Static or bump allocation is no harder than `malloc`/`free`.

Memory is only copied between modules so within it can mutate memory as much as it likes, which lets you (or your agent) find the most optimal algorithm. If we align code written to the underlying computing model of the von-Neumann-architecture we can get predictably faster performance. We get pockets of speed safely sewn together.

## Content-first: formats & encodings at the center

We believe in using the formats that have stood the test of time. Need a simple uncompressed image format? `image/bmp`. Need vector graphics? `image/svg+xml`. Need a snapshot of a directory of files? `application/x-tar`. Need a snapshot of a website? `application/warc`. Need a collection of structured data? `application/vnd.sqlite3`.

The philosophy of qip is: prefer to add functionality via modules rather than building it into qip itself. This means the aim becomes for qip to produce a format that is easily consumable.

For example, our static site builder produces a [WARC archive](<https://en.wikipedia.org/wiki/WARC_(file_format)>) — it’s up to you to decide how that would be turned into a collection of files. Perhaps you want trailing/ slashes/ in your URLs. Perhaps you don’t. Perhaps you want to add a Nginx config. Perhaps you want to upload the content straight to a S3 bucket with no intermediate files touching disk. This is left up to you. qip produces a simple archive of every page route, and then it’s up to you to determine how to use that.

Another belief is qip is content-first, not file-first. Web pages are made of served content, and that content might be dynamic: there might not be a file representation backing what users see. This unlocks flexibility with the ability to pipeline any content together. Files need a name, permissions, a file system for it to live in. We just want the content inside.

## Benefits

- Small swappable units that you author, either with AI or by hand.
- Deterministic outputs that are easy to test and cache.
- Portable execution that works identically across platforms.
- Explicit input/output contracts securely isolated from disk/network/secrets.
- **Simplicity first**: boring interfaces, predictable behavior
- **Security by default**: sandboxed modules, minimal host surface
- **Focused tools**: compose narrow modules instead of building giant runtimes
- **Long-term maintainability**: contracts over conventions, reproducible pipelines

## Tech choices

`qip` is built in Go using its venerable standard library for file system access, HTTP server, and common format decoding/encoding. The [wazero](https://wazero.io) library is used to run WebAssembly modules in a secure sandbox. WebAssembly modules can be authored in C, Zig, WAT, or any language that targets wasm32.

It specifically does not use WASI. This standard has ballooned in complexity and scope creep. To get stuff done and to support browsers we can use a much smaller contract between hosts and modules.

`qip` favors explicit simple contracts and plain directory layouts over magic.

## Philosophy

Good tools should be:

- easy to compose
- secure by default
- cheap to replace
- work on the web, on native, and the command line
- runnable by agents and by users
