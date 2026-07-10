# htmler

> Turn a folder of Markdown, source code, and Jupyter notebooks into a single, self-contained, beautifully styled HTML page.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white)](htmler.sh)
[![Python: 3.6+](https://img.shields.io/badge/Python-3.6%2B-3776AB?logo=python&logoColor=white)](https://www.python.org/)
[![Zero config](https://img.shields.io/badge/Setup-Zero%20config-success)](#quick-start)

`htmler` is a single Bash script that walks a directory, converts every Markdown / code / notebook file it finds, and stitches them together into **one portable HTML file** with tabbed navigation, full-text search, a table of contents, syntax highlighting, and a light/dark theme. No build step, no servers, no dependencies to install by hand — just run it and open the result in any browser.

---

## Highlights

- **One file, everything inside.** The output is a single `.html` you can email, host on GitHub Pages, or open straight from disk.
- **Multi-document navigation.** A sidebar lists every document (with `README` pinned first); a dropdown and full-text search jump between them instantly.
- **On-this-page table of contents** with scroll-spy that tracks your position.
- **Responsive by design.** Works edge-to-edge on phones and iPads — drawers collapse into overlays, tables scroll, and the layout respects iOS safe areas.
- **Light & dark themes** with an Apple-style "liquid glass" navbar; the choice is remembered across visits.
- **Real syntax highlighting** (highlight.js) with per-block copy buttons and language labels.
- **GitHub-flavored extras:** task-list checkboxes, tables, footnote-style cross-document links, heading anchors that match GitHub slugs, and LaTeX math rendering.
- **More than Markdown.** Source files and Jupyter notebooks are rendered as highlighted code/prose automatically.
- **Portable & self-healing.** It finds a suitable Python 3 interpreter on its own and installs the one Python dependency (`markdown`) on the fly if it is missing.

## Quick start

```bash
# Make it executable once
chmod +x htmler.sh

# From inside any docs folder: discover and convert everything
./htmler.sh

# Open the result
open combine_docs.html        # macOS
xdg-open combine_docs.html    # Linux
```

That's it. By default `htmler` recursively finds every supported file under the current directory and writes `combine_docs.html`.

## Installation

`htmler` is a standalone script — clone the repo (or just copy `htmler.sh`) and put it somewhere on your `PATH`:

```bash
git clone https://github.com/nageshnnazare/htmler.git
cd htmler
chmod +x htmler.sh

# Optional: make it available everywhere
ln -s "$(pwd)/htmler.sh" ~/bin/htmler.sh
```

### Requirements

| Requirement | Notes |
|-------------|-------|
| Bash        | Ships with macOS and Linux. |
| Python ≥ 3.6 | Auto-detected; override with `PYTHON_BIN=/path/to/python3`. |
| `markdown`  | Installed automatically (`pip install --user`) if absent. |

An internet connection is only needed the first time, to fetch fonts and the highlight.js theme from a CDN (and to install `markdown` if missing).

## Usage

```text
htmler.sh [-o output.html] [-f file ...] [file ...]

  -o output.html   Name of the generated HTML (default: combine_docs.html)
  -f file          Include a specific file (repeatable). May also be passed as
                   positional arguments or as a glob. When any files are given,
                   ONLY those files are included, in the order provided.
  -h               Show usage.

  (no files)       Default: recursively discover every supported file under the
                   current directory, with README pinned to the top.
```

### Examples

```bash
# Convert everything under the current directory (default)
./htmler.sh

# Custom output name
./htmler.sh -o guide.html

# A hand-picked, ordered set of files
./htmler.sh -o guide.html -f README.md -f docs/intro.md -f docs/api.md

# A list after a single -f
./htmler.sh -f README.md HOWTO.md CHANGELOG.md

# Globs (expanded by your shell, or quoted and expanded by htmler)
./htmler.sh -o api.html -f 'docs/*.md'
./htmler.sh -o all.html -f 'docs/**/*.md'

# Mix Markdown with source files and notebooks
./htmler.sh -o project.html -f README.md -f src/main.cpp -f notebooks/demo.ipynb
```

### Supported file types

| Type | Extensions |
|------|-----------|
| Markdown  | `.md` |
| C / C++   | `.c`, `.cc`, `.cxx`, `.c++`, `.cpp`, `.h`, `.hpp` |
| CUDA      | `.cu` |
| Python    | `.py` |
| Jupyter   | `.ipynb` |

Source files are wrapped in fenced code blocks with the right language for highlighting; notebooks have their Markdown and code cells rendered in order.

## Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| `Ctrl/⌘ + K` | Open full-text search |
| `Ctrl/⌘ + B` | Toggle the documents sidebar |
| `Ctrl/⌘ + I` | Toggle the on-this-page table of contents |
| `Ctrl/⌘ + Shift + L` | Switch light / dark theme |

## Configuration

| Variable | Purpose |
|----------|---------|
| `PYTHON_BIN` | Force a specific interpreter, e.g. `PYTHON_BIN=/usr/bin/python3.11 ./htmler.sh`. Must be Python ≥ 3.6. |

If `python3` on your machine points at an ancient build, `htmler` automatically prefers a newer versioned interpreter (`python3.13` … `python3.6`) and verifies the version before using it.

## How it works

1. **Bash** parses options, resolves the file list (explicit `-f`/positional/glob, or recursive discovery), and locates a capable Python interpreter.
2. **Python** converts each file with the `markdown` library (fenced code, tables, task lists, smart typography, GitHub-style heading anchors, and LaTeX math via MathJax), rendering notebooks and source files as needed.
3. All documents are embedded into one HTML template along with the CSS/JS that powers the tabs, search index, table of contents, theming, and responsive layout.

## License

[MIT](LICENSE) © Nagesh Nazare
