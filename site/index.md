# qip: _pockets of speed safely sewn together_

## Small, secure, and predictable software components

`qip` is a tool for running vibe-coded WebAssembly modules in a strict, composable pipeline. Each module does one focused job: parser, validator, shader, converter, renderer, and so on.

It lets you process text/images/data then compose modules into ever greater units such as a website or image effect pipeline.

Think of it as “React components but for everything and that run anywhere.”

Planned host integrations include Swift, React, and Elixir, pushing further toward write once, run anywhere.

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
| qip run examples/svg-recolor-current-color.wasm '?color_rgba=0xff7722ff' \
examples/svg-rasterize.wasm \
examples/bmp-to-ico.wasm \
> cog.ico
```

<form>
    <qip-preview>
        <source src="/view-source/dynamic/svg-recolor-current-color.wasm" type="application/wasm" data-uniform-color_rgba="0xff7722ff" />
        <source src="/view-source/dynamic/svg-rasterize.wasm" type="application/wasm" />
        <source src="/view-source/dynamic/bmp-to-ico.wasm" type="application/wasm" />
        <textarea name="input"></textarea>
        <output name="output"></output>
    </qip-preview>
</form>

## Markdown

TODO: add Markdown example. Show using `qip comply` to validate against CommonMark.

```bash
wget https://raw.githubusercontent.com/commonmark/commonmark-spec/refs/heads/master/spec.txt
```

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
