#!/bin/bash
# htmler.sh -- Convert .md and code files to a single tabbed HTML
#
# Uses Python markdown library for proper semantic HTML conversion,
# styled to match the nvim vscode dark theme + markview.nvim rendering.
# Features: syntax-highlighted code blocks, light/dark mode toggle, custom output name.
# Supports: Markdown (.md), C/C++/CUDA (.c, .cpp, .cu, .h, .hpp) files.
# Code files are automatically wrapped in markdown code blocks with syntax highlighting.
# v6: Added support for C/C++/CUDA code files.
#
# Usage: ./htmler.sh [-o output.html] [-f file.md|file.c|file.cpp ...] [file ...]
#   -o output.html   Name of the generated HTML (default: combine_docs.html)
#   -f file          Include a specific file (.md, .c, .cpp, .cu, .h, .hpp).
#                    Repeatable. May also be given as positional arguments.
#                    When any files are specified, ONLY those files are included,
#                    in the order given.
#   (no files)       Default: recursively discover every .md and code file under cwd.
# Output: combine_docs.html (default) or specified file in the current directory
# Author: Nagesh N Nazare

set -euo pipefail

OUTPUT_NAME="combine_docs.html"
MD_FILES=()

usage() {
    echo "Usage: $0 [-o output.html] [-f file.md|file.c|file.cpp ...] [file ...]" >&2
}

while getopts "o:f:h" opt; do
    case "$opt" in
        o) OUTPUT_NAME="$OPTARG" ;;
        f) MD_FILES+=("$OPTARG") ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

# Any remaining positional arguments are also treated as explicit .md files.
if [ "$#" -gt 0 ]; then
    MD_FILES+=("$@")
fi

SCRIPT_DIR="$(pwd)"
FINAL="$SCRIPT_DIR/$OUTPUT_NAME"

# Try to get repo name and author from git remote
if git_url=$(git config --get remote.origin.url 2>/dev/null); then
    # Extract repo name and author from git URL (handles both SSH and HTTPS)
    # SSH: git@github.com:user/repo.git -> user/repo
    # HTTPS: https://github.com/user/repo.git -> user/repo
    REPO_NAME=$(echo ${git_url} | sed 's|https://github.com/||' | sed 's|.git||')
else
    # Fall back to output filename
    REPO_NAME="$(basename "$OUTPUT_NAME" .html | sed 's/[_-]/ /g')"
fi

# Construct title as "Author/RepoName"
TITLE="$REPO_NAME"

# Locate a usable Python 3 interpreter. Honor an explicit $PYTHON_BIN override,
# otherwise probe common names/locations on PATH. This keeps the script portable
# across machines instead of hard-coding /usr/bin/python3.6.
_py_is_ok() {
    # Accept only a real Python >= 3.6 (older 3.x lacks pip/FileNotFoundError/etc.).
    "$1" -c 'import sys; sys.exit(0 if sys.version_info[:2] >= (3, 6) else 1)' >/dev/null 2>&1
}
find_python() {
    local cand p
    if [ -n "${PYTHON_BIN:-}" ]; then
        if ! p="$(command -v "$PYTHON_BIN" 2>/dev/null)"; then
            echo "ERROR: PYTHON_BIN='$PYTHON_BIN' is not executable." >&2
            return 1
        fi
        if _py_is_ok "$p"; then
            echo "$p"
            return 0
        fi
        echo "ERROR: PYTHON_BIN='$PYTHON_BIN' is older than Python 3.6." >&2
        return 1
    fi
    # Probe specific modern versions BEFORE the bare 'python3' name, because on
    # some systems 'python3' points at an ancient build (e.g. 3.1). Verify each
    # candidate's version and pick the first one that is >= 3.6.
    for cand in python3.13 python3.12 python3.11 python3.10 python3.9 python3.8 python3.7 python3.6 python3 python; do
        if p="$(command -v "$cand" 2>/dev/null)" && _py_is_ok "$p"; then
            echo "$p"
            return 0
        fi
    done
    # Fall back to common absolute locations that may not be on PATH.
    for p in /usr/bin/python3.* /usr/local/bin/python3.* /opt/*/bin/python3.*; do
        if [ -x "$p" ] && _py_is_ok "$p"; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

PYTHON_BIN="$(find_python)" || {
    echo "ERROR: No Python >= 3.6 interpreter found. Install Python 3.6+ or set PYTHON_BIN=/path/to/python3.6." >&2
    exit 1
}

"$PYTHON_BIN" - "$SCRIPT_DIR" "$FINAL" "$TITLE" ${MD_FILES[@]+"${MD_FILES[@]}"} << 'PYTHON_SCRIPT'
import sys, os, glob, re, html, json

src_dir = sys.argv[1]
out_file = sys.argv[2]
doc_title = sys.argv[3]
explicit_files = sys.argv[4:]  # optional, user-specified .md files (-f / positional)

def collect_md_files(root):
    """Find every .md file under root (recursively), skipping noise dirs."""
    skip = {'.git', 'node_modules', '.venv', 'venv', '__pycache__', '.idea', '.vscode'}
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in skip and not d.startswith('.')]
        for fn in filenames:
            fn_lower = fn.lower()
            if fn_lower.endswith('.md') or fn_lower.endswith(('.c', '.cpp', '.cu', '.h', '.hpp', '.py', '.ipynb')):
                found.append(os.path.join(dirpath, fn))
    return found


def order_key(abs_path):
    """Sort key: top-level README first, then by path depth then name."""
    rel = os.path.relpath(abs_path, src_dir).replace(os.sep, '/')
    name = os.path.basename(rel).lower()
    depth = rel.count('/')
    # 0 = root README (highest priority), 1 = everything else.
    is_root_readme = (depth == 0 and name == 'readme.md')
    return (0 if is_root_readme else 1, depth, rel.lower())


def resolve_explicit(paths):
    """Resolve user-specified files into an ordered list.

    Each argument may be a plain path or a glob pattern (e.g. dir1/*.md,
    docs/**/*.md). Patterns are matched relative to src_dir when not absolute.
    Order between arguments is preserved; matches within one glob are sorted.
    Supports .md files and code files (.c, .cpp, .cu, .h, .hpp, .py, .ipynb).
    """
    import glob as _glob
    resolved = []
    seen = set()
    for p in paths:
        base = p if os.path.isabs(p) else os.path.join(src_dir, p)
        if any(ch in p for ch in '*?['):
            matches = sorted(_glob.glob(base, recursive=True))
            if not matches:
                print("[!] No files match pattern:", p, file=sys.stderr)
                continue
        else:
            matches = [base]
        for cand in matches:
            cand = os.path.normpath(cand)
            cand_lower = cand.lower()
            # Accept .md files or code files
            if not (cand_lower.endswith('.md') or cand_lower.endswith(('.c', '.cpp', '.cu', '.h', '.hpp', '.py', '.ipynb'))):
                print("[!] Skipping non-supported file:", cand, file=sys.stderr)
                continue
            if not os.path.isfile(cand):
                print("[!] Skipping missing file:", cand, file=sys.stderr)
                continue
            key = os.path.normcase(cand)
            if key in seen:
                continue
            seen.add(key)
            resolved.append(cand)
    return resolved


if explicit_files:
    # Only include the files the user asked for, in the given order.
    md_files = resolve_explicit(explicit_files)
    if not md_files:
        print("No valid .md files among the specified arguments.", file=sys.stderr)
        sys.exit(1)
else:
    # Default: recursively discover every .md file (README first).
    md_files = sorted(collect_md_files(src_dir), key=order_key)
    if not md_files:
        print("No .md files found under", src_dir, file=sys.stderr)
        sys.exit(1)

import subprocess, importlib


def _pip_install(pip_name):
    """Install a package into the user site, tolerating PEP-668 'externally
    managed' environments by retrying with --break-system-packages."""
    attempts = [
        [sys.executable, '-m', 'pip', 'install', '--user', pip_name],
        [sys.executable, '-m', 'pip', 'install', '--user', '--break-system-packages', pip_name],
    ]
    for cmd in attempts:
        try:
            subprocess.check_call(cmd)
            return True
        except (subprocess.CalledProcessError, FileNotFoundError):
            continue
    # pip may be absent entirely; try to bootstrap it once, then retry.
    try:
        subprocess.check_call([sys.executable, '-m', 'ensurepip', '--user'])
        subprocess.check_call(attempts[0])
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


def ensure_import(module_name, pip_name=None):
    pip_name = pip_name or module_name
    try:
        return importlib.import_module(module_name)
    except ImportError:
        pass
    print("[*] Python package '%s' not found -> installing '%s' (pip --user)..."
          % (module_name, pip_name), file=sys.stderr)
    if not _pip_install(pip_name):
        print("ERROR: failed to auto-install '%s'. Install it manually with: "
              "pip install --user %s" % (pip_name, pip_name), file=sys.stderr)
        sys.exit(1)
    # Make the freshly installed user-site visible to this running process.
    try:
        import site
        user_site = site.getusersitepackages()
        if user_site and user_site not in sys.path:
            sys.path.insert(0, user_site)
    except Exception:
        pass
    importlib.invalidate_caches()
    try:
        return importlib.import_module(module_name)
    except ImportError:
        print("ERROR: '%s' still not importable after installation." % module_name,
              file=sys.stderr)
        sys.exit(1)


markdown = ensure_import('markdown')

def github_slugify(value, separator):
    """Mimic GitHub's heading-anchor slugify so hand-written in-doc anchor
    links like (#52-object-layout--this) line up with generated heading ids."""
    value = value.strip().lower()
    # drop everything that is not a word char, whitespace or hyphen
    value = re.sub(r'[^\w\s-]', '', value, flags=re.UNICODE)
    # GitHub turns each space into a hyphen WITHOUT collapsing runs,
    # which is how "a & b" -> "a--b"
    value = value.replace(' ', separator)
    return value

md_converter = markdown.Markdown(extensions=[
    'fenced_code',
    'tables',
    'sane_lists',
    'smarty',
    'attr_list',
    'toc',
], extension_configs={
    'toc': {'slugify': github_slugify, 'separator': '-'},
})

TASK_UNCHECKED_RE = re.compile(r'<li>\s*\[ \]\s*')
TASK_CHECKED_RE = re.compile(r'<li>\s*\[[xX]\]\s*')


def render_task_lists(body):
    """Turn `- [ ]` / `- [x]` list items into real (read-only) checkboxes."""
    body = TASK_UNCHECKED_RE.sub(
        '<li class="task-list-item"><input type="checkbox" disabled> ', body)
    body = TASK_CHECKED_RE.sub(
        '<li class="task-list-item"><input type="checkbox" checked disabled> ', body)
    return body


# GitHub-style admonitions: "> [!NOTE]" blockquotes -> styled callout boxes.
# Done entirely at build time so there is zero runtime/JS cost.
CALLOUT_RE = re.compile(
    r'<blockquote>\s*<p>\s*\[!(NOTE|TIP|WARNING|IMPORTANT|CAUTION)\]\s*'
    r'(?:<br\s*/?>)?\s*(.*?)</blockquote>',
    re.DOTALL | re.IGNORECASE)

CALLOUT_TITLES = {
    'note': 'Note', 'tip': 'Tip', 'warning': 'Warning',
    'important': 'Important', 'caution': 'Caution',
}


def render_callouts(body):
    """Convert `> [!NOTE]`-style blockquotes into semantic callout panels."""
    def repl(m):
        kind = m.group(1).lower()
        rest = m.group(2)
        title = CALLOUT_TITLES.get(kind, kind.title())
        inner = '<p>' + rest if not rest.lstrip().startswith('</p>') else rest
        return ('<div class="callout callout-{k}">'
                '<div class="callout-title">{t}</div>'
                '<div class="callout-body">{b}</div></div>').format(
                    k=kind, t=title, b=inner)
    return CALLOUT_RE.sub(repl, body)


_TAG_RE = re.compile(r'<[^>]+>')


def estimate_reading(body_html):
    """Rough word count + reading-time (minutes) for the doc meta line."""
    text = html.unescape(_TAG_RE.sub(' ', body_html))
    words = len(text.split())
    minutes = max(1, int(round(words / 200.0)))
    return words, minutes


# ── ```diagram blocks → nested, colored boxes (rendered at build time) ──────
# A small indentation-based DSL, e.g.:
#
#   ```diagram
#   title: 9.1 Architecture
#   box[blue] Command
#     text: detail / auto / opt
#     box[green] InternalEnable (RAII scope guard)
#       text: Activated at **do()**, **chk()** scope
#     box[red dashed] InternalForceDisable
#       text: Overrides InternalEnable to **DISABLE** recovery
#   ```
#
# Nesting is driven purely by leading-space indentation. Output is plain
# HTML/CSS — no runtime JavaScript and no external libraries.
DIAGRAM_FENCE_RE = re.compile(
    r'(?ms)^[ \t]*```[ \t]*diagram[ \t]*\n(.*?)\n[ \t]*```[ \t]*'
    r'(?:\s*\n[ \t]*```[^\n]*\n(.*?)\n[ \t]*```[ \t]*)?')

# Alternative authoring form for "ASCII in the .md, boxes in the HTML":
# put the DSL inside an HTML comment (invisible to Markdown viewers) and keep
# the human-readable ASCII art in a normal fenced block right after it. At build
# time we render the comment into boxes and DROP the immediately-following ASCII
# fence, so the .md shows ASCII and the generated HTML shows the boxes.
#
#   <!--diagram
#   title: shared_ptr layout
#   box[blue] sp
#     text: ptr -> Widget object
#   -->
#   ```
#   sp ┌────────┐
#      │ ptr ───┼──▶ [ Widget ]
#      └────────┘
#   ```
#
# The trailing ASCII fence is OPTIONAL: a bare <!--diagram ... --> comment just
# renders the boxes at that spot.
DIAGRAM_COMMENT_RE = re.compile(
    r'(?ms)^[ \t]*<!--[ \t]*diagram[ \t]*\n'        # comment opener
    r'(.*?)'                                           # DSL body (group 1)
    r'^[ \t]*-->[ \t]*'                                # comment closer
    r'(?:\s*\n[ \t]*```[^\n]*\n(.*?)\n[ \t]*```[ \t]*)?')

_DBOX_RE = re.compile(r'^box\s*\[([^\]]*)\]\s*(.*)$', re.IGNORECASE)
_DIAGRAM_COLORS = {'blue', 'green', 'orange', 'red', 'purple', 'teal',
                   'gray', 'grey'}


def _diagram_inline(text):
    """Escape HTML then apply the tiny inline markup the DSL understands."""
    out = html.escape(text, quote=False)
    out = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', out)
    out = re.sub(r'`([^`]+?)`', r'<code>\1</code>', out)
    return out


def render_ascii_diagram(src):
    """Render an ASCII diagram as a collapsed details/summary block."""
    body = html.escape(src.rstrip('\n'), quote=False)
    return ('<details class="ascii-diagram">'
            '<summary>Details</summary>'
            '<pre><code>%s</code></pre>'
            '</details>') % body


def render_diagram_dsl(src):
    """Parse the diagram DSL into nested box HTML."""
    root = {'type': 'root', 'title': None, 'children': []}
    stack = [(-1, root)]  # (indent, node) — root never pops
    for raw in src.split('\n'):
        if not raw.strip():
            continue
        indent = len(raw) - len(raw.lstrip(' '))
        content = raw.strip()
        if content.lower().startswith('title:'):
            if root['title'] is None:
                root['title'] = content.split(':', 1)[1].strip()
            continue
        m = _DBOX_RE.match(content)
        if m:
            attrs = [a for a in re.split(r'[\s,]+', m.group(1).strip().lower()) if a]
            node = {
                'type': 'box',
                'title': m.group(2).strip(),
                'colors': [a for a in attrs if a in _DIAGRAM_COLORS],
                'dashed': 'dashed' in attrs,
                'children': [],
            }
            while len(stack) > 1 and stack[-1][0] >= indent:
                stack.pop()
            stack[-1][1]['children'].append(node)
            stack.append((indent, node))
            continue
        if content.lower().startswith('text:'):
            content = content.split(':', 1)[1].strip()
        node = {'type': 'text', 'text': content}
        while len(stack) > 1 and stack[-1][0] >= indent:
            stack.pop()
        stack[-1][1]['children'].append(node)

    def render(children):
        parts = []
        for c in children:
            if c['type'] == 'box':
                classes = ['dbox'] + c['colors'] + (['dashed'] if c['dashed'] else [])
                title = ('<div class="dbox-title">%s</div>' % _diagram_inline(c['title'])
                         if c['title'] else '')
                parts.append('<div class="%s">%s%s</div>' % (
                    ' '.join(classes), title, render(c['children'])))
            else:
                parts.append('<div class="dtext">%s</div>' % _diagram_inline(c['text']))
        return ''.join(parts)

    inner = ''
    if root['title']:
        inner += '<div class="diagram-title">%s</div>' % _diagram_inline(root['title'])
    inner += render(root['children'])
    return '<div class="diagram">%s</div>' % inner

def prettify(component):
    """Turn a path component like '03_patterns' into 'Patterns'."""
    c = re.sub(r'^[0-9]+[_-]', '', component)
    c = c.replace('_', ' ').replace('-', ' ').strip()
    if c.lower() == 'readme':
        return 'README'
    if c.lower() == 'cheatsheet':
        return 'Cheatsheet'
    return c.title() if c else component


def make_label(rel_path):
    """Build a human label from a relative path. Files named README take the
    name of their containing folder so they don't all collapse to 'README'."""
    parts = rel_path.replace(os.sep, '/').split('/')
    parts[-1] = os.path.splitext(parts[-1])[0]
    if parts[-1].lower() == 'readme' and len(parts) > 1:
        parts = parts[:-1]
    cleaned = [prettify(p) for p in parts]
    cleaned = [c for c in cleaned if c]
    return ' / '.join(cleaned) if cleaned else 'README'


def get_language_from_extension(filepath):
    """Map file extension to markdown language identifier."""
    ext_map = {
        '.c': 'c',
        '.cpp': 'cpp',
        '.cc': 'cpp',
        '.cxx': 'cpp',
        '.c++': 'cpp',
        '.cu': 'cuda',
        '.h': 'c',
        '.hpp': 'cpp',
        '.py': 'python',
    }
    ext = os.path.splitext(filepath)[1].lower()
    return ext_map.get(ext, 'text')


def wrap_code_file_as_markdown(filepath):
    """Read a code file and wrap it in a markdown fenced code block."""
    with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
        code_content = f.read()
    
    # Get the filename for a title
    filename = os.path.basename(filepath)
    lang = get_language_from_extension(filepath)
    
    # Create markdown with heading and code block
    md_content = f"# {filename}\n\n```{lang}\n{code_content}\n```\n"
    return md_content


def wrap_ipynb_file_as_markdown(filepath):
    """Read a Jupyter Notebook (.ipynb) file and wrap its cells as markdown/code blocks."""
    try:
        with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
            nb = json.load(f)
        md_cells = []
        filename = os.path.basename(filepath)
        md_cells.append(f"# {filename}\n")
        
        cells = nb.get('cells', [])
        for cell in cells:
            cell_type = cell.get('cell_type')
            source_lines = cell.get('source', [])
            if isinstance(source_lines, str):
                source = source_lines
            else:
                source = "".join(source_lines)
            
            if cell_type == 'markdown':
                md_cells.append(source + "\n")
            elif cell_type == 'code':
                exec_cnt = cell.get('execution_count')
                exec_label = f" [{exec_cnt}]" if exec_cnt is not None else ""
                md_cells.append(f"###### [In{exec_label}]:\n```python\n{source}\n```\n")
        return "\n".join(md_cells)
    except Exception as e:
        return f"# {os.path.basename(filepath)}\n\nError parsing notebook: {e}\n"


def fix_cuddled_lists(text):
    """Ensure cuddled lists (lists immediately following a paragraph without a blank line)
    are separated by a blank line so that python-markdown renders them as lists."""
    lines = text.splitlines()
    new_lines = []
    in_code_block = False
    
    # Regex to match the start of a list item (ordered or unordered)
    # e.g., 1. Item, - Item, * Item, + Item
    list_item_re = re.compile(r'^\s*(\d+\.|[\*\-+])\s+')
    
    for i, line in enumerate(lines):
        # Track if we are inside a fenced code block to avoid modifying code
        if line.strip().startswith('```'):
            in_code_block = not in_code_block
            new_lines.append(line)
            continue
            
        if in_code_block:
            new_lines.append(line)
            continue
            
        if list_item_re.match(line):
            if i > 0:
                prev_line = lines[i-1]
                prev_stripped = prev_line.strip()
                # If the previous line has text, is not a list item itself,
                # and is not a header, blockquote, or horizontal rule, insert a blank line.
                if (prev_stripped and 
                    not list_item_re.match(prev_line) and 
                    not prev_stripped.startswith('#') and 
                    not prev_stripped.startswith('>') and 
                    not (prev_stripped.startswith('---') or prev_stripped.startswith('***') or prev_stripped.startswith('___'))):
                    new_lines.append('')
                    
        new_lines.append(line)
        
    return '\n'.join(new_lines)


tabs = []
for order, md_path in enumerate(md_files, start=1):
    rel_path = os.path.relpath(md_path, src_dir).replace(os.sep, '/')
    rel_noext = os.path.splitext(rel_path)[0]
    rel_dir = os.path.dirname(rel_path)
    label = make_label(rel_path)
    tab_name = "{0}. {1}".format(order, label)

    # Check if it's a code file or notebook and wrap/parse it accordingly
    if rel_path.lower().endswith(('.c', '.cpp', '.cu', '.h', '.hpp', '.py')):
        md_text = wrap_code_file_as_markdown(md_path)
    elif rel_path.lower().endswith('.ipynb'):
        md_text = wrap_ipynb_file_as_markdown(md_path)
    else:
        with open(md_path, 'r', encoding='utf-8', errors='replace') as f:
            md_text = f.read()

    # Pull ```diagram blocks out before markdown sees them (their indentation
    # and custom syntax must not be touched), leaving a plain-text token we
    # swap back for the rendered HTML afterwards.
    diagram_html = []

    def _stash_diagram(m):
        rendered = render_diagram_dsl(m.group(1))
        ascii_src = m.group(2) if m.lastindex and m.lastindex >= 2 else None
        if ascii_src is not None:
            rendered += render_ascii_diagram(ascii_src)
        diagram_html.append(rendered)
        return '\n\nDIAGRAMBLOCK%dENDDIAGRAM\n\n' % (len(diagram_html) - 1)

    # Comment form first (it may capture an optional trailing ASCII fence),
    # then the plain ```diagram fenced form.
    md_text = DIAGRAM_COMMENT_RE.sub(_stash_diagram, md_text)
    md_text = DIAGRAM_FENCE_RE.sub(_stash_diagram, md_text)

    md_text = fix_cuddled_lists(md_text)
    md_converter.reset()
    body_html = md_converter.convert(md_text)
    body_html = render_task_lists(body_html)
    body_html = render_callouts(body_html)
    for i, dhtml in enumerate(diagram_html):
        token = 'DIAGRAMBLOCK%dENDDIAGRAM' % i
        body_html = body_html.replace('<p>%s</p>' % token, dhtml)
        body_html = body_html.replace(token, dhtml)
    words, mins = estimate_reading(body_html)
    tabs.append({
        'name': tab_name,
        'path': rel_path,        # e.g. 01_pthreads/README.md
        'pathNoExt': rel_noext,  # e.g. 01_pthreads/README
        'dir': rel_dir,          # e.g. 01_pthreads  ('' for root)
        'body': body_html,
        'words': words,
        'mins': mins,
    })
    print("[*] Converted {0} -> {1}".format(rel_path, tab_name))

def js_escape(s):
    return s.replace('\\', '\\\\').replace('`', '\\`').replace('${', '\\${')

tab_js_entries = []
for t in tabs:
    escaped_name = js_escape(t['name'])
    escaped_path = js_escape(t['path'])
    escaped_dir = js_escape(t['dir'])
    escaped_body = js_escape(t['body'])
    tab_js_entries.append(
        '  {{ name: `{name}`, path: `{path}`, dir: `{dir}`, words: {words}, mins: {mins}, body: `{body}` }}'.format(
            name=escaped_name, path=escaped_path, dir=escaped_dir,
            words=t['words'], mins=t['mins'], body=escaped_body))

tab_data_js = 'const TAB_DATA = [\n' + ',\n'.join(tab_js_entries) + '\n];'

escaped_title = html.escape(doc_title)

HTML_TEMPLATE = r'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>%%DOC_TITLE%% &mdash; Documentation</title>
<!-- Favicon: the brand "book" glyph (same as the sidebar toggle) on an accent tile -->
<link rel="icon" type="image/svg+xml" href="data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%20viewBox='0%200%2032%2032'%3E%3Crect%20width='32'%20height='32'%20rx='7'%20fill='%236cb1f0'/%3E%3Cg%20transform='translate(8%208)'%20fill='%23ffffff'%3E%3Cpath%20d='M0%201.75A.75.75%200%200%201%20.75%201h4.253c1.227%200%202.317.59%203%201.501A3.743%203.743%200%200%201%2011.006%201h4.245a.75.75%200%200%201%20.75.75v10.5a.75.75%200%200%201-.75.75h-4.507a2.25%202.25%200%200%200-1.591.659l-.622.621a.75.75%200%200%201-1.06%200l-.622-.621A2.25%202.25%200%200%200%205.258%2013H.75a.75.75%200%200%201-.75-.75Zm7.251%2010.324.004-5.073-.002-2.253A2.25%202.25%200%200%200%205.003%202.5H1.5v9h3.757a3.75%203.75%200%200%201%201.994.574ZM8.755%204.75l-.004%207.322a3.752%203.752%200%200%201%201.992-.572H14.5v-9h-3.495a2.25%202.25%200%200%200-2.25%202.25Z'/%3E%3C/g%3E%3C/svg%3E">
<!-- Typography -->
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;500;600&display=swap">
<!-- highlight.js for syntax highlighting (VS Code dark+ theme) -->
<link id="hljs-theme" rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/vs2015.min.css">
<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
<style>
/* === CSS Custom Properties for theming === */
/* - Nagesh N Nazare - */
:root {
    --header-height: 56px;
    --sidebar-width: 280px;
    /* Let the document fill the available width (no wasted screen real-estate). */
    --content-max: none;

    --font-sans: "Inter", -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
    --font-mono: "JetBrains Mono", "SF Mono", "Cascadia Code", "Fira Code", "Consolas", monospace;

    --radius-sm: 6px;
    --radius-md: 10px;
    --radius-lg: 14px;

    --shadow-sm: 0 1px 2px rgba(0,0,0,0.35);
    --shadow-md: 0 8px 24px rgba(0,0,0,0.35);
    --shadow-lg: 0 24px 64px rgba(0,0,0,0.55);

    --bg-body: #0b0d12;
    --bg-header: rgba(15,17,23,0.82);
    /* Apple-style "liquid glass" navbar (dark) */
    --glass-bg: linear-gradient(180deg, rgba(28,31,42,0.62) 0%, rgba(13,15,20,0.46) 100%);
    --glass-tint: rgba(20,22,30,0.30);
    --glass-border: rgba(255,255,255,0.10);
    --glass-highlight: rgba(255,255,255,0.14);
    --glass-shadow: 0 10px 30px rgba(0,0,0,0.45);
    --glass-blur: 22px;
    /* Shared liquid-glass backdrop filter: moderate blur + saturation so the
       page behind shows through (transparent), Apple-style, without a milky fill. */
    --glass-filter: blur(18px) saturate(200%);
    /* Floating glass controls (dark) -- transparent, the blur does the work. */
    --ctrl-bg: rgba(255,255,255,0.04);
    --ctrl-bg-hover: rgba(255,255,255,0.09);
    --ctrl-border: rgba(255,255,255,0.12);
    --ctrl-shadow: 0 4px 18px rgba(0,0,0,0.30), inset 0 1px 0 rgba(255,255,255,0.18);
    --ctrl-shadow-hover: 0 8px 26px rgba(0,0,0,0.38), inset 0 1px 0 rgba(255,255,255,0.26);
    /* Light-catching rim gradient: a single highlight on the top-left diagonal
       edge that fades to nothing before reaching the opposite side -- the
       asymmetric, Apple-style refractive glass edge. */
    --glass-rim: linear-gradient(135deg, rgba(255,255,255,0.32) 0%, rgba(255,255,255,0.08) 16%, rgba(255,255,255,0) 42%);
    --bg-sidebar: #0e1016;
    --bg-content: #0b0d12;
    --bg-code-block: #14161f;
    --bg-code-inline: #1b1e2a;
    --bg-heading: transparent;
    --bg-table-even: #14161f;
    --bg-table-head: #181b27;
    --bg-blockquote: #13161f;
    --bg-search-input: #1b1e2a;
    --bg-search-overlay-inner: #13151d;
    --bg-search-overlay-bg: rgba(4,5,8,0.66);
    --bg-sr-item-hover: #1b1e2a;
    --bg-sr-item-border: #1c1f2b;
    --bg-highlight: #6b3d12;

    --border-main: #1f2230;
    --border-header: #242838;
    --border-input: #2a2e40;
    --border-table: #262a3a;
    --border-code: #23273a;

    --text-primary: #d6d8e3;
    --text-secondary: #969ab4;
    --text-muted: #5e6280;
    --text-heading-h1: #6cb1f0;
    --text-heading-h2: #e0a07f;
    --text-heading-h3: #e2e08c;
    --text-heading-h4: #82c46b;
    --text-code-inline: #e0a07f;
    --text-link: #6cb1f0;
    --text-link-hover: #9bcbf7;
    --text-strong: #e8eaf2;
    --text-tab-active: #6cb1f0;
    --text-mark-fg: #ffd98a;
    --text-blockquote: #aab0cc;
    --text-table-header: #6cb1f0;

    --accent: #6cb1f0;
    --accent-soft: rgba(108,177,240,0.14);
    --accent-strong: rgba(108,177,240,0.32);

    --sidebar-toggle-bg: #1b1e2a;
    --sidebar-toggle-border: #2a2e40;
    --sidebar-toggle-hover: #262a3a;
    --nav-active-bg: rgba(108,177,240,0.12);
    --nav-doc-active-bg: var(--accent);
    --nav-doc-active-fg: #0a0f17;
    --scrollbar-thumb: #2a2e40;

    /* Diagram (```diagram) box accent palette */
    --d-blue: #5aa2f0;
    --d-green: #56c98a;
    --d-orange: #e0a23c;
    --d-red: #e8666f;
    --d-purple: #b58cf0;
    --d-teal: #45c4c4;
    --d-gray: #9aa0b4;
}

[data-theme="light"] {
    --shadow-sm: 0 1px 2px rgba(16,24,40,0.06);
    --shadow-md: 0 8px 24px rgba(16,24,40,0.10);
    --shadow-lg: 0 24px 64px rgba(16,24,40,0.18);

    --bg-body: #f6f7fb;
    --bg-header: rgba(255,255,255,0.85);
    /* Apple-style "liquid glass" navbar (light) */
    --glass-bg: linear-gradient(180deg, rgba(255,255,255,0.78) 0%, rgba(245,247,251,0.55) 100%);
    --glass-tint: rgba(255,255,255,0.35);
    --glass-border: rgba(255,255,255,0.65);
    --glass-highlight: rgba(255,255,255,0.85);
    --glass-shadow: 0 10px 30px rgba(16,24,40,0.12);
    --glass-blur: 22px;
    --glass-filter: blur(18px) saturate(190%);
    /* Floating glass controls (light) -- transparent, the blur does the work. */
    --ctrl-bg: rgba(255,255,255,0.35);
    --ctrl-bg-hover: rgba(255,255,255,0.55);
    --ctrl-border: rgba(255,255,255,0.6);
    --ctrl-shadow: 0 4px 18px rgba(16,24,40,0.10), inset 0 1px 0 rgba(255,255,255,0.8);
    --ctrl-shadow-hover: 0 8px 26px rgba(16,24,40,0.16), inset 0 1px 0 rgba(255,255,255,0.95);
    /* Light-catching rim gradient: brightest at the top-left/bottom-right
       corners, dimmer along the edges -- a refractive glass edge. */
    --glass-rim: linear-gradient(135deg, rgba(255,255,255,0.85) 0%, rgba(255,255,255,0.3) 16%, rgba(255,255,255,0) 42%);
    --bg-sidebar: #ffffff;
    --bg-content: #ffffff;
    --bg-code-block: #f4f5fa;
    --bg-code-inline: #eceef5;
    --bg-heading: transparent;
    --bg-table-even: #f7f8fc;
    --bg-table-head: #eef1f8;
    --bg-blockquote: #f4f6fb;
    --bg-search-input: #f1f2f8;
    --bg-search-overlay-inner: #ffffff;
    --bg-search-overlay-bg: rgba(16,24,40,0.28);
    --bg-sr-item-hover: #f1f3f9;
    --bg-sr-item-border: #ebeef5;
    --bg-highlight: #ffe9a8;

    --border-main: #e4e7f0;
    --border-header: #e0e3ee;
    --border-input: #d4d8e6;
    --border-table: #dde1ec;
    --border-code: #e4e7f0;

    --text-primary: #1f2433;
    --text-secondary: #5a6078;
    --text-muted: #8b90a8;
    --text-heading-h1: #1f6fc4;
    --text-heading-h2: #b25a30;
    --text-heading-h3: #8a7610;
    --text-heading-h4: #3d7a22;
    --text-code-inline: #b25a30;
    --text-link: #1f6fc4;
    --text-link-hover: #14508f;
    --text-strong: #11151f;
    --text-tab-active: #1f6fc4;
    --text-mark-fg: #6b4e00;
    --text-blockquote: #4a5066;
    --text-table-header: #1f6fc4;

    --accent: #1f6fc4;
    --accent-soft: rgba(31,111,196,0.10);
    --accent-strong: rgba(31,111,196,0.22);

    --sidebar-toggle-bg: #ffffff;
    --sidebar-toggle-border: #e0e3ee;
    --sidebar-toggle-hover: #eef1f8;
    --nav-active-bg: rgba(31,111,196,0.10);
    --nav-doc-active-bg: var(--accent);
    --nav-doc-active-fg: #ffffff;
    --scrollbar-thumb: #d0d4e2;

    /* Diagram (```diagram) box accent palette (darker for light bg contrast) */
    --d-blue: #1f6fc4;
    --d-green: #2f8f52;
    --d-orange: #c1771f;
    --d-red: #d23f4a;
    --d-purple: #7d4fd0;
    --d-teal: #1f8a8a;
    --d-gray: #6a7187;
}

/* === Reset & base === */
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

html {
    color-scheme: dark;
    scroll-behavior: smooth;
    /* Honour the device safe-area (notch / home indicator) on iOS. */
    -webkit-text-size-adjust: 100%;
    text-size-adjust: 100%;
    /* Hide the browser's main page scrollbar (right + bottom) while keeping
       the page fully scrollable. Per-component scrollbars (sidebars, code
       blocks, tables) keep their own styled thin scrollbars. */
    scrollbar-width: none;        /* Firefox */
    -ms-overflow-style: none;     /* legacy Edge/IE */
}
html::-webkit-scrollbar,
body::-webkit-scrollbar { width: 0; height: 0; display: none; }  /* WebKit/Blink */
[data-theme="light"] { color-scheme: light; }

body {
    /* - Nagesh N Nazare - */
    font-family: var(--font-sans);
    background: var(--bg-body);
    color: var(--text-primary);
    line-height: 1.7;
    font-size: 15.5px;
    -webkit-font-smoothing: antialiased;
    text-rendering: optimizeLegibility;
    transition: background 0.25s, color 0.25s;
    /* Never let wide code/tables push the whole page sideways on small screens. */
    overflow-x: hidden;
}

::selection { background: var(--accent-strong); }

/* === GitHub-style (Octicon) inline icons === */
.icon {
    display: inline-block;
    width: 16px;
    height: 16px;
    fill: currentColor;
    flex-shrink: 0;
    vertical-align: text-bottom;
    overflow: visible;
}

/* === Header bar (doc selector + search + theme toggle) ===
   The bar itself is fully transparent; the liquid-glass effect lives only on
   the individual floating controls inside it. */
.header-bar {
    background: transparent;
    border: none;
    box-shadow: none;
    position: fixed;
    top: 0;
    left: 0;
    right: 0;
    z-index: 100;
    height: var(--header-height);
    pointer-events: none;
}
/* Re-enable interaction for the actual controls (the bar is click-through). */
.header-inner > * { pointer-events: auto; }

.header-inner {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 0 18px;
    height: 100%;
    min-width: 0;
    position: relative;
}

/* iOS-style condensed title: hidden until the page is scrolled down. */
.nav-doc-title {
    position: absolute;
    left: 50%;
    top: 50%;
    transform: translate(-50%, calc(-50% + 8px));
    max-width: min(60vw, 520px);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    /* Keep this perfectly in sync with .doc-select so the title looks identical
       whether it is shown in the picker or floating in the condensed navbar. */
    font-weight: 600;
    font-size: 13px;
    letter-spacing: -0.01em;
    color: var(--text-primary);
    background: var(--ctrl-bg);
    border: 1px solid var(--ctrl-border);
    box-shadow: var(--ctrl-shadow);
    -webkit-backdrop-filter: var(--glass-filter);
    backdrop-filter: var(--glass-filter);
    padding: 7px 18px;
    border-radius: 999px;
    opacity: 0;
    pointer-events: none;
    transition: opacity 0.4s cubic-bezier(0.32,0.72,0,1), transform 0.4s cubic-bezier(0.32,0.72,0,1);
}

/* Smoothly fade/lift the menu items in and out as the bar condenses. */
.brand-name, .doc-selector, .search-widget {
    transition: opacity 0.4s cubic-bezier(0.32,0.72,0,1), transform 0.4s cubic-bezier(0.32,0.72,0,1);
}

/* Apple-style entrance for the navbar controls when the page first loads:
   a soft fade with a gentle scale-up (no sliding). `backwards` keeps them
   hidden during their delay but reverts to normal afterwards so the condense
   transitions above keep working. */
@keyframes nav-pop-in {
    from { opacity: 0; transform: scale(0.94); }
    to   { opacity: 1; transform: none; }
}
.brand, .doc-selector, .search-widget {
    animation: nav-pop-in 0.6s cubic-bezier(0.32, 0.72, 0, 1) backwards;
}
.brand         { animation-delay: 0.04s; }
.doc-selector  { animation-delay: 0.10s; }
.search-widget { animation-delay: 0.16s; }

@media (prefers-reduced-motion: reduce) {
    .brand, .doc-selector, .search-widget { animation: none; }
}

/* Condensed: keep the sidebar toggle icon, drop the back button, collection
   name + menu items, and reveal the centered document title. */
body.nav-condensed .nav-back,
body.nav-condensed .brand-name,
body.nav-condensed .doc-selector,
body.nav-condensed .search-widget {
    opacity: 0;
    transform: translateY(-8px);
    pointer-events: none;
}
body.nav-condensed .nav-doc-title {
    opacity: 1;
    transform: translate(-50%, -50%);
    pointer-events: auto;
}

.brand {
    display: flex;
    align-items: center;
    gap: 10px;
    font-weight: 700;
    font-size: 14px;
    letter-spacing: -0.01em;
    color: var(--text-primary);
    white-space: nowrap;
    flex-shrink: 0;
    margin-right: 2px;
}
/* The document title is the dominant element of the navbar. */
.brand-name {
    font-size: 18px;
    font-weight: 800;
    letter-spacing: -0.02em;
    /*text-transform: capitalize;*/
    color: var(--accent);
    background: linear-gradient(180deg, var(--text-link-hover), var(--accent));
    -webkit-background-clip: text;
    background-clip: text;
    -webkit-text-fill-color: transparent;
}
.doc-selector {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
    flex-shrink: 1;
    /* Push the picker to the right so it sits alongside the navbar buttons. */
    margin-left: auto;
}

.doc-selector-label {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: 11px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    color: var(--text-muted);
    white-space: nowrap;
    flex-shrink: 0;
}
.doc-selector-label .icon { width: 14px; height: 14px; }

.doc-select {
    background: var(--ctrl-bg);
    border: 1px solid var(--ctrl-border);
    box-shadow: var(--ctrl-shadow);
    -webkit-backdrop-filter: var(--glass-filter);
    backdrop-filter: var(--glass-filter);
    color: var(--text-primary);
    font-family: inherit;
    font-size: 13px;
    font-weight: 600;
    /* Match the 36px height of the navbar icon buttons exactly. */
    box-sizing: border-box;
    height: 36px;
    padding: 0 30px 0 14px;
    border-radius: 999px;
    outline: none;
    cursor: pointer;
    min-width: 160px;
    max-width: min(420px, 42vw);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    /* Transition only background-color (not the `background` shorthand) so the
       chevron icon never fades/slides on hover. Apple-style easing. */
    transition: border-color 0.3s ease, background-color 0.3s cubic-bezier(0.32,0.72,0,1), color 0.25s ease, box-shadow 0.3s cubic-bezier(0.32,0.72,0,1), transform 0.3s cubic-bezier(0.32,0.72,0,1);
    appearance: none;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 12 12'%3E%3Cpath fill='%23888' d='M3 4.5L6 7.5L9 4.5'/%3E%3C/svg%3E");
    background-repeat: no-repeat;
    background-position: right 12px center;
}

.doc-select:hover {
    background-color: var(--ctrl-bg-hover);
    box-shadow: var(--ctrl-shadow-hover);
    transform: scale(1.02);
}
.doc-select:active { transform: scale(0.98); }
.doc-select:focus { border-color: var(--accent); }

/* === Floating circular icon buttons (Apple-style) ===
   The title/sidebar toggle, theme toggle and search button share one identical
   look so every navbar icon matches. */
.brand-toggle,
.nav-back,
.theme-toggle,
.search-toggle,
.toc-toggle,
.doc-nav {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    /* A 36px-tall pill: with no label it stays square (=> circle via the big
       radius); on hover it grows to fit the text label. */
    min-width: 36px;
    height: 36px;
    padding: 0;
    border-radius: 999px;
    background: var(--ctrl-bg);
    border: 1px solid var(--ctrl-border);
    box-shadow: var(--ctrl-shadow);
    -webkit-backdrop-filter: var(--glass-filter);
    backdrop-filter: var(--glass-filter);
    color: var(--text-secondary);
    cursor: pointer;
    font-size: 16px;
    flex-shrink: 0;
    position: relative;
    /* Apple-style easing: gentle, no overshoot. */
    transition: background 0.3s cubic-bezier(0.32,0.72,0,1), color 0.2s ease, border-color 0.3s ease, box-shadow 0.3s cubic-bezier(0.32,0.72,0,1), transform 0.3s cubic-bezier(0.32,0.72,0,1), opacity 0.2s ease, padding 0.34s cubic-bezier(0.32,0.72,0,1);
}
/* Refractive liquid-glass rim: a bright, light-catching highlight that traces
   the edges and corners of each button. Built as a gradient "border" using the
   mask-compositing trick so only the 1px ring is painted. */
.brand-toggle::after,
.nav-back::after,
.theme-toggle::after,
.search-toggle::after,
.toc-toggle::after,
.doc-nav::after {
    content: "";
    position: absolute;
    inset: 0;
    border-radius: inherit;
    padding: 1px;
    background: var(--glass-rim);
    -webkit-mask: linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0);
            mask: linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0);
    -webkit-mask-composite: xor;
            mask-composite: exclude;
    pointer-events: none;
    opacity: 0.7;
    transition: opacity 0.3s cubic-bezier(0.32,0.72,0,1);
}
.brand-toggle:hover::after,
.nav-back:hover::after,
.theme-toggle:hover::after,
.search-toggle:hover::after,
.toc-toggle:hover::after,
.doc-nav:hover::after { opacity: 0.95; }
.brand-toggle:hover,
.nav-back:hover,
.theme-toggle:hover,
.search-toggle:hover,
.toc-toggle:hover,
.doc-nav:hover {
    background: var(--ctrl-bg-hover);
    color: var(--accent);
    box-shadow: var(--ctrl-shadow-hover);
}
/* Hover-to-expand pill: only buttons that actually contain a .btn-label child
   widen on hover. Removing the <span class="btn-label"> from a button's markup
   disables its expansion while keeping all of this styling intact. */
.brand-toggle:has(.btn-label):hover,
.nav-back:has(.btn-label):hover,
.theme-toggle:has(.btn-label):hover,
.search-toggle:has(.btn-label):hover,
.toc-toggle:has(.btn-label):hover,
.doc-nav:has(.btn-label):hover {
    padding: 0 14px;
}
.brand-toggle:active,
.nav-back:active,
.theme-toggle:active,
.search-toggle:active,
.toc-toggle:active,
.doc-nav:active { transform: scale(0.94); }
.brand-toggle .icon,
.nav-back .icon,
.theme-toggle .icon,
.search-toggle .icon,
.toc-toggle .icon,
.doc-nav .icon { width: 17px; height: 17px; }

/* === Hover-to-expand button labels === */
.btn-label {
    display: inline-block;
    max-width: 0;
    opacity: 0;
    margin-left: 0;
    overflow: hidden;
    white-space: nowrap;
    font-family: var(--font-sans);
    font-size: 13px;
    font-weight: 600;
    letter-spacing: -0.01em;
    line-height: 1;
    transition: max-width 0.36s cubic-bezier(0.32,0.72,0,1),
                opacity 0.28s ease,
                margin-left 0.36s cubic-bezier(0.32,0.72,0,1);
}
.brand-toggle:hover .btn-label,
.nav-back:hover .btn-label,
.theme-toggle:hover .btn-label,
.search-toggle:hover .btn-label,
.toc-toggle:hover .btn-label,
.doc-nav:hover .btn-label {
    max-width: 120px;
    opacity: 1;
    margin-left: 8px;
}
@media (prefers-reduced-motion: reduce) {
    .btn-label { transition: none; }
}

/* Navbar button groups: prev/next live in their own wrapper, the search/theme/
   TOC tools in another, so the two clusters are visually distinct. */
.nav-btn-group {
    display: inline-flex;
    align-items: center;
    gap: 8px;
}

/* History-back and the prev/next buttons dim + disable when there is nowhere
   to go (start/end of the collection, or no navigation history yet). */
.nav-back:disabled,
.doc-nav:disabled {
    opacity: 0.32;
    cursor: default;
    pointer-events: none;
    box-shadow: var(--ctrl-shadow);
    transform: none;
}

/* The brand/sidebar toggle icon carries the brand accent color. It stays a
   fixed circular branding mark and does NOT expand into a labelled pill. */
.brand-toggle { color: var(--accent); }
.brand-toggle:hover { color: var(--text-link-hover); padding: 0; }

/* === Search widget === */
.search-widget {
    padding: 0;
    display: flex;
    align-items: center;
    gap: 14px;          /* larger gap separates the two button groups */
    flex-shrink: 0;
}

.search-kbd {
    color: var(--text-muted);
    font-size: 11px;
    font-family: var(--font-mono);
    background: var(--ctrl-bg);
    border: 1px solid var(--ctrl-border);
    box-shadow: var(--ctrl-shadow);
    -webkit-backdrop-filter: var(--glass-filter);
    backdrop-filter: var(--glass-filter);
    border-radius: 999px;
    padding: 3px 9px;
    line-height: 1.4;
}

/* === Search results panel === */
.search-results {
    display: none;
    position: fixed;
    top: 0; left: 0; right: 0; bottom: 0;
    z-index: 200;
    background: var(--bg-search-overlay-bg);
}

.search-results.open { display: flex; justify-content: center; padding-top: 60px; }

.search-results-inner {
    background: var(--bg-search-overlay-inner);
    border: 1px solid var(--border-header);
    border-radius: 8px;
    width: min(720px, 94vw);
    max-height: 70vh;
    display: flex;
    flex-direction: column;
    box-shadow: 0 16px 48px rgba(0,0,0,0.5);
    transition: background 0.25s, border-color 0.25s;
}

.sr-header {
    padding: 12px 16px;
    border-bottom: 1px solid var(--border-input);
    display: flex;
    align-items: center;
    gap: 10px;
    flex-shrink: 0;
}

.sr-header input {
    flex: 1;
    background: var(--bg-body);
    border: 1px solid var(--border-input);
    color: var(--text-primary);
    font-family: inherit;
    font-size: 14px;
    padding: 8px 12px;
    border-radius: 4px;
    outline: none;
    transition: background 0.25s, border-color 0.25s, color 0.25s;
}
.sr-header input:focus { border-color: var(--text-tab-active); }
.sr-header input::placeholder { color: var(--text-muted); }

.sr-count {
    color: var(--text-muted);
    font-size: 12px;
    white-space: nowrap;
    flex-shrink: 0;
}

.sr-body {
    overflow-y: auto;
    flex: 1;
    padding: 4px 0;
}

.sr-empty {
    color: var(--text-muted);
    text-align: center;
    padding: 32px 16px;
    font-size: 14px;
}

.sr-item {
    padding: 8px 16px;
    cursor: pointer;
    border-bottom: 1px solid var(--bg-sr-item-border);
    transition: background 0.1s;
}
.sr-item:hover, .sr-item.sr-active { background: var(--bg-sr-item-hover); }

.sr-item-tab {
    font-size: 11px;
    font-weight: 600;
    color: var(--text-tab-active);
    margin-bottom: 2px;
}

.sr-item-heading {
    font-size: 12px;
    color: var(--text-heading-h2);
    margin-bottom: 3px;
}

.sr-item-snippet {
    font-size: 13px;
    color: var(--text-secondary);
    line-height: 1.45;
    overflow: hidden;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
}

.sr-item-snippet mark, .search-highlight {
    background: var(--bg-highlight);
    color: var(--text-mark-fg);
    border-radius: 2px;
    padding: 0 1px;
}

/* === Page layout: sidebar + content === */
.page-layout {
    display: flex;
    min-height: 100vh;
}

/* === Sidebar nav (Left) & TOC (Right) ===
   The sidebars span the full viewport height so their backgrounds meet the navbar
   seamlessly. */
.sidebar-nav {
    width: var(--sidebar-width);
    min-width: var(--sidebar-width);
    background: var(--bg-sidebar);
    border-right: 1px solid var(--border-main);
    position: sticky;
    top: 0;
    height: 100vh;
    padding-top: var(--header-height);
    overflow-y: auto;
    overflow-x: hidden;
    flex-shrink: 0;
    transition: width 0.2s, min-width 0.2s, padding 0.2s, opacity 0.2s, background 0.25s, border-color 0.25s;
    z-index: 50;
    scrollbar-width: thin;
    scrollbar-color: var(--scrollbar-thumb) var(--bg-sidebar);
}
.sidebar-nav::-webkit-scrollbar { width: 5px; }
.sidebar-nav::-webkit-scrollbar-track { background: var(--bg-sidebar); }
.sidebar-nav::-webkit-scrollbar-thumb { background: var(--scrollbar-thumb); border-radius: 3px; }

.sidebar-nav.collapsed {
    width: 0;
    min-width: 0;
    padding: 0;
    opacity: 0;
    pointer-events: none;
}

.toc-sidebar {
    width: var(--sidebar-width);
    min-width: var(--sidebar-width);
    background: var(--bg-sidebar);
    border-left: 1px solid var(--border-main);
    position: sticky;
    top: 0;
    height: 100vh;
    padding-top: var(--header-height);
    overflow-y: auto;
    overflow-x: hidden;
    flex-shrink: 0;
    transition: width 0.2s, min-width 0.2s, padding 0.2s, opacity 0.2s, background 0.25s, border-color 0.25s;
    z-index: 50;
    scrollbar-width: thin;
    scrollbar-color: var(--scrollbar-thumb) var(--bg-sidebar);
}
.toc-sidebar::-webkit-scrollbar { width: 5px; }
.toc-sidebar::-webkit-scrollbar-track { background: var(--bg-sidebar); }
.toc-sidebar::-webkit-scrollbar-thumb { background: var(--scrollbar-thumb); border-radius: 3px; }

.toc-sidebar.collapsed {
    width: 0;
    min-width: 0;
    padding: 0;
    opacity: 0;
    pointer-events: none;
}

.nav-title {
    display: flex;
    align-items: center;
    gap: 7px;
    font-size: 10px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1.2px;
    color: var(--text-muted);
    padding: 14px 14px 6px;
}
.nav-title .icon { width: 13px; height: 13px; opacity: 0.85; }

/* Directory Tree Structure Styling */
.nav-dir-item {
    list-style: none;
    margin: 4px 0;
}
.nav-dir-header {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 5px 8px;
    color: var(--text-secondary);
    font-size: 12.5px;
    font-weight: 600;
    cursor: pointer;
    border-radius: var(--radius-sm);
    user-select: none;
    transition: background 0.15s, color 0.15s;
}
.nav-dir-header:hover {
    color: var(--text-primary);
    background: var(--bg-code-block);
}
.nav-dir-header .chevron-icon {
    width: 14px;
    height: 14px;
    opacity: 0.7;
    transition: transform 0.2s ease;
}
.nav-dir-header .folder-icon {
    width: 15px;
    height: 15px;
    color: var(--accent);
}
.nav-dir-children {
    list-style: none;
    margin-left: 12px;
    padding-left: 6px;
    border-left: 1px dashed var(--border-main);
}
.nav-dir-item:not(.expanded) > .nav-dir-children {
    display: none;
}
.nav-dir-item.expanded > .nav-dir-header .chevron-icon {
    transform: rotate(90deg);
}

.nav-list {
    list-style: none;
    padding: 0 6px 16px;
    margin: 0;
}

/* Apple-style fade-in for the navigation entries each time a sidebar opens. */
@keyframes nav-item-in {
    from { opacity: 0; transform: scale(0.98); }
    to   { opacity: 1; transform: none; }
}
/* Both sidebars share the exact same entrance. The left "Documents" tree nests
   its file entries inside .nav-dir-children (not .nav-list), so it must be
   covered too -- otherwise nested items wouldn't animate and the two sidebars
   would look mismatched. */
.sidebar-nav:not(.collapsed) .nav-list > li,
.sidebar-nav:not(.collapsed) .nav-dir-children > li,
.toc-sidebar:not(.collapsed) .nav-list > li {
    animation: nav-item-in 0.4s cubic-bezier(0.32, 0.72, 0, 1) backwards;
}
.nav-list > li:nth-child(1), .nav-dir-children > li:nth-child(1) { animation-delay: 0.02s; }
.nav-list > li:nth-child(2), .nav-dir-children > li:nth-child(2) { animation-delay: 0.05s; }
.nav-list > li:nth-child(3), .nav-dir-children > li:nth-child(3) { animation-delay: 0.08s; }
.nav-list > li:nth-child(4), .nav-dir-children > li:nth-child(4) { animation-delay: 0.11s; }
.nav-list > li:nth-child(5), .nav-dir-children > li:nth-child(5) { animation-delay: 0.14s; }
.nav-list > li:nth-child(6), .nav-dir-children > li:nth-child(6) { animation-delay: 0.17s; }
.nav-list > li:nth-child(n+7), .nav-dir-children > li:nth-child(n+7) { animation-delay: 0.2s; }
@media (prefers-reduced-motion: reduce) {
    .sidebar-nav:not(.collapsed) .nav-list > li,
    .sidebar-nav:not(.collapsed) .nav-dir-children > li,
    .toc-sidebar:not(.collapsed) .nav-list > li { animation: none; }
}

.nav-list a {
    display: block;
    padding: 3px 10px;
    color: var(--text-secondary);
    text-decoration: none;
    font-size: 12px;
    line-height: 1.5;
    border-radius: 3px;
    border-left: 2px solid transparent;
    transition: color 0.12s, background 0.12s, border-color 0.12s;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.nav-list a:hover {
    color: var(--text-primary);
    background: var(--bg-code-block);
}

.nav-list a.nav-active {
    color: var(--text-tab-active);
    background: var(--nav-active-bg);
    border-left-color: var(--text-tab-active);
}

.nav-list .nav-h1 { padding-left: 10px; font-weight: 600; color: var(--text-secondary); margin-top: 6px; }
.nav-list .nav-h2 { padding-left: 20px; }
.nav-list .nav-h3 { padding-left: 30px; font-size: 11px; }
.nav-list .nav-h4 { padding-left: 40px; font-size: 11px; color: var(--text-muted); }

/* Active document: a solid, filled pill so it stands out distinctly from the
   subtle heading scroll-spy highlight. */
#docList a.nav-doc-active {
    color: var(--nav-doc-active-fg);
    background: var(--nav-doc-active-bg);
    border-left-color: transparent;
    font-weight: 700;
    box-shadow: 0 2px 8px var(--accent-strong);
}
#docList a.nav-doc-active:hover {
    color: var(--nav-doc-active-fg);
    background: var(--nav-doc-active-bg);
}

.sidebar-section + .sidebar-section {
    border-top: 1px solid var(--border-main);
}

/* === Tab content === */
.content-area {
    flex: 1;
    min-width: 0;
    padding: calc(var(--header-height) + 28px) 40px 80px;
}

.tab-content {
    display: none;
    max-width: var(--content-max);
    margin: 0 auto;
    background: var(--bg-content);
    border: 1px solid var(--border-main);
    border-radius: var(--radius-lg);
    padding: 40px 48px 56px;
    box-shadow: var(--shadow-sm);
    transition: background 0.25s, border-color 0.25s;
}
.tab-content.active { display: block; animation: fade-in 0.45s cubic-bezier(0.32, 0.72, 0, 1); }

@keyframes fade-in {
    from { opacity: 0; transform: scale(0.99); }
    to   { opacity: 1; transform: none; }
}

/* === Reading progress bar (top of viewport) === */
.read-progress {
    position: fixed;
    top: 0; left: 0;
    height: 2px;
    width: 0;
    background: linear-gradient(90deg, var(--accent), var(--text-link-hover));
    z-index: 120;
    pointer-events: none;
    /* width is set imperatively; keep the easing tiny so it tracks the scroll. */
    transition: width 0.08s linear;
}

/* === Skip-to-content (keyboard / screen-reader) === */
.skip-link {
    position: fixed;
    top: 8px;
    left: 50%;
    transform: translateX(-50%) translateY(-150%);
    z-index: 300;
    background: var(--accent);
    color: var(--nav-doc-active-fg);
    font-weight: 700;
    font-size: 13px;
    padding: 8px 16px;
    border-radius: 999px;
    text-decoration: none;
    transition: transform 0.2s ease;
}
.skip-link:focus { transform: translateX(-50%) translateY(0); }

/* === Doc meta line (breadcrumb + reading time) === */
.doc-meta {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px 12px;
    margin-bottom: 22px;
    font-size: 12px;
    color: var(--text-muted);
}
.doc-breadcrumb { display: inline-flex; align-items: center; gap: 6px; min-width: 0; }
.doc-breadcrumb .crumb-sep { opacity: 0.5; }
.doc-reading-time {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    margin-left: auto;
    white-space: nowrap;
}
.doc-reading-time .icon { width: 13px; height: 13px; }

/* === Back-to-top floating button === */
.to-top {
    position: fixed;
    right: 22px;
    bottom: 22px;
    width: 40px;
    height: 40px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border-radius: 50%;
    background: var(--ctrl-bg);
    border: 1px solid var(--ctrl-border);
    box-shadow: var(--ctrl-shadow);
    -webkit-backdrop-filter: var(--glass-filter);
    backdrop-filter: var(--glass-filter);
    color: var(--text-secondary);
    cursor: pointer;
    z-index: 110;
    opacity: 0;
    transform: translateY(12px) scale(0.9);
    pointer-events: none;
    transition: opacity 0.3s cubic-bezier(0.32,0.72,0,1), transform 0.3s cubic-bezier(0.32,0.72,0,1), color 0.2s, background 0.2s;
}
.to-top.show { opacity: 1; transform: none; pointer-events: auto; }
.to-top:hover { color: var(--accent); background: var(--ctrl-bg-hover); }
.to-top:active { transform: scale(0.92); }
.to-top .icon { width: 18px; height: 18px; }

/* === Heading permalink anchors === */
.tab-content .heading-anchor {
    position: relative;
    opacity: 0;
    margin-left: 8px;
    font-size: 0.8em;
    color: var(--text-muted);
    text-decoration: none;
    border-bottom: none;
    cursor: pointer;
    transition: opacity 0.15s, color 0.15s;
}
.tab-content h1:hover .heading-anchor,
.tab-content h2:hover .heading-anchor,
.tab-content h3:hover .heading-anchor,
.tab-content h4:hover .heading-anchor { opacity: 0.7; }
.tab-content .heading-anchor:hover { opacity: 1; color: var(--accent); background: none; }

/* "Link copied" confirmation bubble shown after clicking a permalink. */
.tab-content .heading-anchor.copied { opacity: 1; color: var(--text-heading-h4); }
.tab-content .heading-anchor.copied::after {
    content: "Link copied";
    position: absolute;
    left: 50%;
    bottom: calc(100% + 6px);
    transform: translateX(-50%);
    background: var(--accent);
    color: var(--nav-doc-active-fg);
    font-family: var(--font-sans);
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0;
    padding: 3px 8px;
    border-radius: 6px;
    white-space: nowrap;
    pointer-events: none;
    box-shadow: var(--shadow-md);
    animation: anchor-tip 1.4s ease forwards;
}
@keyframes anchor-tip {
    0%      { opacity: 0; transform: translateX(-50%) translateY(4px); }
    12%, 78% { opacity: 1; transform: translateX(-50%) translateY(0); }
    100%    { opacity: 0; transform: translateX(-50%) translateY(-3px); }
}

/* === Callouts / admonitions (built at conversion time) === */
.callout {
    margin: 18px 0;
    padding: 12px 16px 12px 14px;
    border: 1px solid var(--border-main);
    border-left: 3px solid var(--accent);
    border-radius: 0 var(--radius-md) var(--radius-md) 0;
    background: var(--bg-blockquote);
}
.callout-title {
    font-weight: 700;
    font-size: 13px;
    letter-spacing: 0.01em;
    margin-bottom: 4px;
    color: var(--accent);
}
.callout-body > :first-child { margin-top: 0; }
.callout-body > :last-child { margin-bottom: 0; }
.callout-note      { border-left-color: var(--text-link);     }
.callout-note .callout-title    { color: var(--text-link);     }
.callout-tip       { border-left-color: var(--text-heading-h4); }
.callout-tip .callout-title     { color: var(--text-heading-h4); }
.callout-important { border-left-color: var(--text-heading-h3); }
.callout-important .callout-title { color: var(--text-heading-h3); }
.callout-warning   { border-left-color: var(--text-heading-h2); }
.callout-warning .callout-title { color: var(--text-heading-h2); }
.callout-caution   { border-left-color: #e0555f; }
.callout-caution .callout-title { color: #e0555f; }

/* === Diagrams (```diagram blocks, rendered to nested boxes at build time) === */
.diagram {
    margin: 22px 0;
    padding: 24px 24px 28px;
    border: 1px solid var(--border-main);
    border-radius: var(--radius-lg, 16px);
    background: linear-gradient(180deg, rgba(127,127,127,0.04), transparent);
}
.diagram-title {
    font-size: 17px;
    font-weight: 800;
    letter-spacing: -0.01em;
    color: var(--text-primary);
    margin-bottom: 16px;
}
/* A titled box. Title sits on the top border like a fieldset legend. */
.dbox {
    position: relative;
    border: 1.5px solid var(--dbox-color, var(--border-main));
    border-radius: 13px;
    padding: 20px 20px 18px;
    margin-top: 22px;
    background: var(--dbox-fill, rgba(127,127,127,0.03));
    box-shadow: inset 0 1px 0 rgba(255,255,255,0.04), var(--shadow-md);
}
.dbox:first-child { margin-top: 4px; }
.dbox > .dbox-title {
    position: absolute;
    top: -9px;
    left: 18px;
    padding: 1px 10px;
    border-radius: 7px;
    font-size: 11px;
    font-weight: 800;
    letter-spacing: 1px;
    text-transform: uppercase;
    color: var(--dbox-color, var(--text-primary));
    background: var(--bg-content);
}
.dbox.dashed { border-style: dashed; }
.dtext {
    color: var(--text-secondary);
    font-size: 14px;
    line-height: 1.55;
    margin: 8px 0;
}
.dtext:first-of-type { margin-top: 4px; }
.dtext:last-child { margin-bottom: 0; }
.dtext b { color: var(--text-primary); font-weight: 700; }
.dtext code, .dbox-title code {
    font-family: var(--font-mono);
    font-size: 0.92em;
    background: var(--bg-code-inline);
    padding: 1px 5px;
    border-radius: 5px;
}
/* color variants drive both border + legend via a single custom property */
.dbox.blue   { --dbox-color: var(--d-blue);   --dbox-fill: color-mix(in srgb, var(--d-blue) 7%, transparent); }
.dbox.green  { --dbox-color: var(--d-green);  --dbox-fill: color-mix(in srgb, var(--d-green) 7%, transparent); }
.dbox.orange { --dbox-color: var(--d-orange); --dbox-fill: color-mix(in srgb, var(--d-orange) 7%, transparent); }
.dbox.red    { --dbox-color: var(--d-red);    --dbox-fill: color-mix(in srgb, var(--d-red) 7%, transparent); }
.dbox.purple { --dbox-color: var(--d-purple); --dbox-fill: color-mix(in srgb, var(--d-purple) 7%, transparent); }
.dbox.teal   { --dbox-color: var(--d-teal);   --dbox-fill: color-mix(in srgb, var(--d-teal) 7%, transparent); }
.dbox.gray   { --dbox-color: var(--d-gray);   --dbox-fill: color-mix(in srgb, var(--d-gray) 7%, transparent); }

/* === Visible keyboard focus rings === */
/* Keyboard focus ring. Do NOT set border-radius here -- modern browsers round
   the outline to the element's own radius, and forcing a radius would square
   off the pill-shaped document selector when focused. */
:focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: 2px;
}
.doc-select:focus-visible, .nav-list a:focus-visible { outline-offset: 1px; }

/* === Headings === */
.tab-content h1, .tab-content h2, .tab-content h3,
.tab-content h4, .tab-content h5, .tab-content h6 {
    font-weight: 700;
    letter-spacing: -0.012em;
    scroll-margin-top: calc(var(--header-height) + 18px);
    transition: color 0.25s;
}

.tab-content h1 {
    font-size: 2.0em;
    color: var(--text-heading-h1);
    margin: 0 0 22px;
    padding-bottom: 16px;
    border-bottom: 1px solid var(--border-main);
}
.tab-content h1:first-child { margin-top: 0; }

.tab-content h2 {
    font-size: 1.5em;
    color: var(--text-heading-h2);
    margin: 40px 0 14px;
    padding-left: 14px;
    border-left: 3px solid var(--text-heading-h2);
}

.tab-content h3 {
    font-size: 1.22em;
    color: var(--text-heading-h3);
    margin: 30px 0 10px;
}

.tab-content h4 {
    font-size: 1.08em;
    color: var(--text-heading-h4);
    margin: 24px 0 8px;
}

.tab-content h5 {
    font-size: 1.0em;
    color: var(--text-heading-h1);
    margin: 18px 0 6px;
}

.tab-content h6 {
    font-size: 0.92em;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-secondary);
    margin: 16px 0 6px;
}

/* === Paragraphs & text === */
.tab-content p { margin: 12px 0; }

.tab-content strong { color: var(--text-strong); font-weight: 700; }
.tab-content em { color: var(--text-primary); font-style: italic; }

/* === Inline code === */
.tab-content code {
    font-family: var(--font-mono);
    color: var(--text-code-inline);
    background: var(--bg-code-inline);
    padding: 0.12em 0.42em;
    border-radius: 5px;
    font-size: 0.86em;
    border: 1px solid var(--border-code);
    transition: background 0.25s, color 0.25s;
}

/* === Fenced code blocks === */
.tab-content pre {
    background: var(--bg-code-block);
    border: 1px solid var(--border-code);
    border-radius: var(--radius-md);
    padding: 18px 18px 16px;
    margin: 16px 0;
    overflow-x: auto;
    line-height: 1.55;
    position: relative;
    box-shadow: var(--shadow-sm);
    transition: background 0.25s, border-color 0.25s;
    scrollbar-width: thin;
    scrollbar-color: var(--scrollbar-thumb) transparent;
}
.tab-content pre::-webkit-scrollbar { height: 8px; }
.tab-content pre::-webkit-scrollbar-thumb { background: var(--scrollbar-thumb); border-radius: 4px; }

.tab-content pre code {
    background: transparent;
    color: var(--text-primary);
    padding: 0;
    border: none;
    font-size: 13.5px;
}

/* Override highlight.js background to match our theme */
.tab-content pre code.hljs {
    background: transparent !important;
    padding: 0 !important;
}

/* Language label on code blocks */
.code-lang-label {
    position: absolute;
    top: 8px;
    right: 12px;
    font-size: 10px;
    font-family: var(--font-mono);
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 0.6px;
    pointer-events: none;
    opacity: 0.75;
}

/* Copy-to-clipboard button */
.code-copy-btn {
    position: absolute;
    top: 6px;
    right: 8px;
    display: inline-flex;
    align-items: center;
    gap: 5px;
    font-family: var(--font-sans);
    font-size: 11px;
    font-weight: 600;
    color: var(--text-secondary);
    background: var(--bg-code-inline);
    border: 1px solid var(--border-input);
    border-radius: 6px;
    padding: 4px 9px;
    cursor: pointer;
    opacity: 0;
    transform: translateY(-2px);
    transition: opacity 0.15s, background 0.15s, color 0.15s, transform 0.15s;
}
.tab-content pre:hover .code-copy-btn { opacity: 1; transform: none; }
.code-copy-btn:hover { color: var(--text-primary); background: var(--sidebar-toggle-hover); border-color: var(--accent); }
.code-copy-btn.copied { color: var(--text-heading-h4); border-color: var(--text-heading-h4); }
.tab-content pre:hover .code-lang-label { opacity: 0; }

/* === Lists === */
.tab-content ul, .tab-content ol {
    margin: 12px 0 12px 4px;
    padding-left: 26px;
}
.tab-content ul { list-style: none; }
.tab-content ul > li { position: relative; padding-left: 4px; }
.tab-content ul > li::before {
    content: "";
    position: absolute;
    left: -16px;
    top: 0.72em;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--accent);
    opacity: 0.85;
}
.tab-content ul ul > li::before {
    background: transparent;
    border: 1.5px solid var(--accent);
    width: 6px; height: 6px;
}

.tab-content li { margin: 6px 0; }
.tab-content ol li::marker { color: var(--accent); font-weight: 700; }

.tab-content li > ul, .tab-content li > ol { margin-top: 6px; margin-bottom: 6px; }

/* Task-list checkboxes (- [ ] / - [x]) */
.tab-content li.task-list-item { list-style: none; padding-left: 0; }
.tab-content li.task-list-item::before { display: none; }
.tab-content li.task-list-item input[type="checkbox"] {
    appearance: none;
    -webkit-appearance: none;
    width: 17px; height: 17px;
    margin: 0 9px -3px -22px;
    border: 1.5px solid var(--border-input);
    border-radius: 5px;
    background: var(--bg-code-inline);
    position: relative;
    vertical-align: baseline;
    cursor: default;
}
.tab-content li.task-list-item input[type="checkbox"]:checked {
    background: var(--accent);
    border-color: var(--accent);
}
.tab-content li.task-list-item input[type="checkbox"]:checked::after {
    content: "";
    position: absolute;
    left: 5px; top: 1px;
    width: 4px; height: 9px;
    border: solid #0b0d12;
    border-width: 0 2px 2px 0;
    transform: rotate(45deg);
}

/* === Links === */
.tab-content a {
    color: var(--text-link);
    text-decoration: none;
    border-bottom: 1px solid var(--accent-strong);
    transition: color 0.15s, border-color 0.15s, background 0.15s;
    border-radius: 2px;
}
.tab-content a:hover {
    color: var(--text-link-hover);
    border-bottom-color: var(--text-link-hover);
    background: var(--accent-soft);
}
/* Cross-document links get a subtle trailing arrow to signal navigation */
.tab-content a.xref-link::after {
    content: "\2197";
    font-size: 0.78em;
    margin-left: 2px;
    opacity: 0.55;
    vertical-align: super;
    line-height: 0;
}

/* === Tables === */
.tab-content table {
    border-collapse: separate;
    border-spacing: 0;
    margin: 18px 0;
    width: 100%;
    font-size: 14px;
    border: 1px solid var(--border-table);
    border-radius: var(--radius-md);
    overflow: hidden;
    box-shadow: var(--shadow-sm);
}

.tab-content th {
    background: var(--bg-table-head);
    color: var(--text-table-header);
    font-weight: 700;
    text-align: left;
    padding: 10px 14px;
    border-bottom: 1px solid var(--border-table);
    transition: background 0.25s, color 0.25s, border-color 0.25s;
}
.tab-content th + th, .tab-content td + td { border-left: 1px solid var(--border-table); }

.tab-content td {
    padding: 9px 14px;
    border-bottom: 1px solid var(--border-table);
    transition: border-color 0.25s;
}
.tab-content tr:last-child td { border-bottom: none; }

.tab-content tbody tr:nth-child(even) td {
    background: var(--bg-table-even);
    transition: background 0.25s;
}
.tab-content tbody tr:hover td { background: var(--accent-soft); }

/* Tables are wrapped (via JS) in a scroll container so wide tables never blow
   out the layout; on narrow screens they scroll horizontally instead. */
.table-scroll {
    max-width: 100%;
    overflow-x: auto;
    -webkit-overflow-scrolling: touch;
    margin: 18px 0;
    scrollbar-width: thin;
    scrollbar-color: var(--scrollbar-thumb) transparent;
}
.table-scroll::-webkit-scrollbar { height: 8px; }
.table-scroll::-webkit-scrollbar-thumb { background: var(--scrollbar-thumb); border-radius: 4px; }
.table-scroll > table { margin: 0; }

/* === Horizontal rules === */
.tab-content hr {
    border: none;
    border-top: 1px solid var(--border-main);
    margin: 32px 0;
}

/* === Blockquotes === */
.tab-content blockquote {
    border-left: 3px solid var(--accent);
    padding: 12px 18px;
    margin: 18px 0;
    color: var(--text-blockquote);
    background: var(--bg-blockquote);
    border-radius: 0 var(--radius-md) var(--radius-md) 0;
    transition: background 0.25s, color 0.25s;
}
.tab-content blockquote p:first-child { margin-top: 0; }
.tab-content blockquote p:last-child { margin-bottom: 0; }

/* === Responsive === */

/* Media never overflows its container. */
.tab-content img,
.tab-content video,
.tab-content svg { max-width: 100%; height: auto; }

/* ---- Tablets & iPad (portrait + landscape): sidebars become overlay drawers ---- */
@media (max-width: 1024px) {
    /* Keep the sidebar toggle reachable; just drop the long collection title so
       the controls fit. The condensed title still names the current doc. */
    .brand-name { display: none; }
    .brand { margin-right: 0; }

    .content-area { padding: calc(var(--header-height) + 18px) 20px 64px; }
    .tab-content { padding: 26px 22px 40px; border-radius: var(--radius-md); }
    .search-kbd { display: none; }

    /* Sidebars float over the content instead of squeezing it. */
    .sidebar-nav, .toc-sidebar {
        position: fixed;
        top: 0;
        height: 100vh;
        z-index: 150;
        background: var(--bg-sidebar);
        box-shadow: var(--shadow-lg);
    }
    .sidebar-nav { left: 0; border-right: 1px solid var(--border-main); }
    .toc-sidebar { right: 0; border-left: 1px solid var(--border-main); }

    /* Dimmed, blurred backdrop while either drawer is open. */
    body::before {
        content: "";
        position: fixed;
        inset: 0;
        background: rgba(0,0,0,0.45);
        backdrop-filter: blur(4px);
        -webkit-backdrop-filter: blur(4px);
        z-index: 140;
        opacity: 0;
        pointer-events: none;
        transition: opacity 0.25s ease;
    }
    body:not(.sidebar-collapsed)::before,
    body:not(.toc-collapsed)::before {
        opacity: 1;
        pointer-events: auto;
    }
}

/* ---- Small tablets / large phones (e.g. iPad portrait, big phones) ---- */
@media (max-width: 768px) {
    /* Respect the notch / rounded corners on iOS. */
    .header-inner {
        gap: 8px;
        padding-left: max(12px, env(safe-area-inset-left));
        padding-right: max(12px, env(safe-area-inset-right));
    }
    /* Let the document picker take whatever width is left (an auto left margin
       would otherwise swallow the free space and block flex-grow). */
    .doc-selector { flex: 1 1 auto; margin-left: 0; }
    .doc-select { min-width: 0; max-width: none; width: 100%; }

    .content-area {
        padding-left: max(14px, env(safe-area-inset-left));
        padding-right: max(14px, env(safe-area-inset-right));
        padding-top: calc(var(--header-height) + 14px);
        padding-bottom: 56px;
    }
    /* Edge-to-edge reading panel on small screens. */
    .tab-content { padding: 22px 16px 36px; border: none; border-radius: 0; box-shadow: none; }
    .tab-content h1 { font-size: 1.7em; }
    .tab-content h2 { font-size: 1.34em; }
    .tab-content h3 { font-size: 1.16em; }

    /* Wide tables grow to their content and scroll inside the wrapper. */
    .table-scroll > table { width: auto; min-width: 100%; }
    /* Long unbroken tokens wrap instead of overflowing. */
    .tab-content p code, .tab-content li code { overflow-wrap: anywhere; word-break: break-word; }

    .sidebar-nav, .toc-sidebar { width: min(86vw, 340px); min-width: 0; }
}

/* ---- Phones ---- */
@media (max-width: 600px) {
    :root { --header-height: 52px; }
    body { font-size: 15px; }
    .doc-selector-label { display: none; }
    /* Header is tight on phones: drop the prev/next pair (the picker still
       switches documents). */
    .nav-btn-group-docnav { display: none; }
    .header-inner { gap: 6px; }
    .search-widget { gap: 6px; }
    /* Comfortable tap targets. */
    .brand-toggle, .theme-toggle, .search-toggle, .toc-toggle { width: 38px; height: 38px; }
    .doc-select { height: 38px; }
    .content-area { padding-top: calc(var(--header-height) + 10px); padding-bottom: 48px; }
    .tab-content { padding: 18px 14px 32px; }
    .tab-content h1 { font-size: 1.5em; padding-bottom: 12px; margin-bottom: 18px; }
    .tab-content h2 { margin: 30px 0 12px; }
    .tab-content pre { padding: 14px 14px 12px; }
    /* No hover on touch, so keep the copy button visible. */
    .code-copy-btn { opacity: 1; transform: none; }
    .nav-doc-title { max-width: 64vw; font-size: 13px; padding: 6px 14px; }
}

/* ---- Very small phones ---- */
@media (max-width: 380px) {
    .header-inner { gap: 4px; padding-left: 8px; padding-right: 8px; }
    .brand-toggle, .theme-toggle, .search-toggle, .toc-toggle { width: 36px; height: 36px; }
    .tab-content { padding: 16px 11px 28px; }
}

/* Devices that can't hover (touch): always show the copy button. */
@media (hover: none) {
    .code-copy-btn { opacity: 1; transform: none; }
    .tab-content pre:hover .code-lang-label { opacity: 1; }
}

/* === Print === */
@media print {
    .header-bar, .sidebar-nav, .toc-sidebar, .sidebar-toggle { display: none !important; }
    .tab-content { display: block !important; page-break-after: always; }
    body { background: white; color: #222; }
    .search-results { display: none !important; }
    .page-layout { display: block; }
}
</style>
</head>
<body data-theme="dark" class="sidebar-collapsed toc-collapsed">
/* - Nagesh N Nazare - */

<a class="skip-link" href="#tabPanels">Skip to content</a>
<div class="read-progress" id="readProgress"></div>

<div class="header-bar">
  <div class="header-inner" id="headerInner">
    <div class="brand">
      <button class="brand-toggle" id="sidebarToggle" title="Toggle sidebar (Ctrl+B)" aria-label="Toggle sidebar">
        <svg class="icon brand-icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M0 1.75A.75.75 0 0 1 .75 1h4.253c1.227 0 2.317.59 3 1.501A3.743 3.743 0 0 1 11.006 1h4.245a.75.75 0 0 1 .75.75v10.5a.75.75 0 0 1-.75.75h-4.507a2.25 2.25 0 0 0-1.591.659l-.622.621a.75.75 0 0 1-1.06 0l-.622-.621A2.25 2.25 0 0 0 5.258 13H.75a.75.75 0 0 1-.75-.75Zm7.251 10.324.004-5.073-.002-2.253A2.25 2.25 0 0 0 5.003 2.5H1.5v9h3.757a3.75 3.75 0 0 1 1.994.574ZM8.755 4.75l-.004 7.322a3.752 3.752 0 0 1 1.992-.572H14.5v-9h-3.495a2.25 2.25 0 0 0-2.25 2.25Z"></path></svg>
      </button>
      <button class="nav-back" id="navBack" title="Go back (Alt+&larr;)" aria-label="Go back" disabled>
        <svg class="icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M6.78 1.97a.75.75 0 0 1 0 1.06L3.81 6h6.44A4.75 4.75 0 0 1 15 10.75v2.5a.75.75 0 0 1-1.5 0v-2.5a3.25 3.25 0 0 0-3.25-3.25H3.81l2.97 2.97a.75.75 0 1 1-1.06 1.06L1.47 7.28a.75.75 0 0 1 0-1.06l4.25-4.25a.75.75 0 0 1 1.06 0Z"></path></svg>
      </button>
      <span class="brand-name">%%DOC_TITLE%%</span>
    </div>
    <div class="doc-selector">
      <select class="doc-select" id="docSelect" title="Switch document"></select>
    </div>
    <div class="search-widget">
      <div class="nav-btn-group nav-btn-group-docnav">
        <button class="doc-nav" id="docPrev" title="Previous document" aria-label="Previous document">
          <svg class="icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M9.78 12.78a.75.75 0 0 1-1.06 0L4.47 8.53a.75.75 0 0 1 0-1.06l4.25-4.25a.75.75 0 0 1 1.06 1.06L6.06 8l3.72 3.72a.75.75 0 0 1 0 1.06Z"></path></svg>
        </button>
        <button class="doc-nav" id="docNext" title="Next document" aria-label="Next document">
          <svg class="icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M6.22 3.22a.75.75 0 0 1 1.06 0l4.25 4.25a.75.75 0 0 1 0 1.06l-4.25 4.25a.75.75 0 0 1-1.06-1.06L9.94 8 6.22 4.28a.75.75 0 0 1 0-1.06Z"></path></svg>
        </button>
      </div>
      <div class="nav-btn-group nav-btn-group-tools">
        <button class="search-toggle" id="searchTrigger" title="Search all documents (Ctrl+K)" aria-label="Search">
          <svg class="icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M10.68 11.74a6 6 0 0 1-7.922-8.982 6 6 0 0 1 8.982 7.922l3.04 3.04a.749.749 0 0 1-.326 1.275.749.749 0 0 1-.734-.215ZM11.5 7a4.499 4.499 0 1 0-8.997 0A4.499 4.499 0 0 0 11.5 7Z"></path></svg>
        </button>
        <button class="theme-toggle" id="themeToggle" title="Toggle light/dark mode (Ctrl+Shift+L)" aria-label="Toggle theme"></button>
        <button class="toc-toggle" id="tocToggle" title="Toggle table of contents (Ctrl+I)" aria-label="Toggle table of contents">
          <svg class="icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M2 4a1 1 0 1 1 0-2 1 1 0 0 1 0 2Zm3.75-1.5h8.5a.75.75 0 0 1 0 1.5h-8.5a.75.75 0 0 1 0-1.5Zm0 5h8.5a.75.75 0 0 1 0 1.5h-8.5a.75.75 0 0 1 0-1.5ZM2 9a1 1 0 1 1 0-2 1 1 0 0 1 0 2Zm1 4a1 1 0 1 1-2 0 1 1 0 0 1 2 0Zm2.75-.5h8.5a.75.75 0 0 1 0 1.5h-8.5a.75.75 0 0 1 0-1.5Z"></path></svg>
        </button>
      </div>
    </div>
    <div class="nav-doc-title" id="navDocTitle" aria-hidden="true"></div>
  </div>
</div>

<div class="search-results" id="searchOverlay">
  <div class="search-results-inner">
    <div class="sr-header">
      <input type="text" id="searchInput" placeholder="Search across all documentation..." autofocus>
      <span class="sr-count" id="srCount"></span>
    </div>
    <div class="sr-body" id="srBody">
      <div class="sr-empty">Type to search across all tabs</div>
    </div>
  </div>
</div>

<div class="page-layout">
  <nav class="sidebar-nav collapsed" id="sidebarNav">
    <div class="sidebar-section" id="docListSection">
      <div class="nav-title">
        <svg class="icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M0 1.75C0 .784.784 0 1.75 0h12.5C15.216 0 16 .784 16 1.75v12.5A1.75 1.75 0 0 1 14.25 16H1.75A1.75 1.75 0 0 1 0 14.25Zm9.5 0v6.396l1.215-.812a.25.25 0 0 1 .27 0l1.215.812V1.75a.25.25 0 0 0-.25-.25h-2.2a.25.25 0 0 0-.25.25Zm-1.5 0a.25.25 0 0 0-.25-.25H1.75a.25.25 0 0 0-.25.25v12.5c0 .138.112.25.25.25H8Zm9.5 12.5V1.75a.25.25 0 0 0-.25-.25H13v8.5a.75.75 0 0 1-1.166.624L10 11.149l-1.834 1.225A.75.75 0 0 1 8 11.75V14.5h6.25a.25.25 0 0 0 .25-.25Z"></path></svg>
        Documents
      </div>
      <ul class="nav-list" id="docList"></ul>
    </div>
  </nav>
  <div class="content-area">
    <div id="tabPanels"></div>
  </div>
  <button class="to-top" id="toTop" title="Back to top" aria-label="Back to top">
    <svg class="icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M3.47 7.78a.75.75 0 0 1 0-1.06l4-4a.75.75 0 0 1 1.06 0l4 4a.75.75 0 0 1-1.06 1.06L8.75 4.81V13a.75.75 0 0 1-1.5 0V4.81L4.53 7.78a.75.75 0 0 1-1.06 0Z"></path></svg>
  </button>
  <nav class="toc-sidebar collapsed" id="tocSidebar">
    <div class="sidebar-section" id="tocSection">
      <div class="nav-title">
        <svg class="icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M5.75 2.5h8.5a.75.75 0 0 1 0 1.5h-8.5a.75.75 0 0 1 0-1.5Zm0 5h8.5a.75.75 0 0 1 0 1.5h-8.5a.75.75 0 0 1 0-1.5Zm0 5h8.5a.75.75 0 0 1 0 1.5h-8.5a.75.75 0 0 1 0-1.5ZM2 14a1 1 0 1 1 0-2 1 1 0 0 1 0 2Zm1-6a1 1 0 1 1-2 0 1 1 0 0 1 2 0ZM2 4a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z"></path></svg>
        On this page
      </div>
      <ul class="nav-list" id="navList"></ul>
    </div>
  </nav>
</div>

<script>
%%TAB_DATA%%

const docSelect = document.getElementById('docSelect');
const docList = document.getElementById('docList');
const tabPanels = document.getElementById('tabPanels');
const navDocTitle = document.getElementById('navDocTitle');
let navLastY = 0;

// Prettify function in JS (matching Python's prettify)
function prettify(component) {
    let c = component.replace(/^[0-9]+[_-]/, '');
    c = c.replace(/_/g, ' ').replace(/-/g, ' ').trim();
    if (c.toLowerCase() === 'readme') return 'README';
    if (c.toLowerCase() === 'cheatsheet') return 'Cheatsheet';
    return c.replace(/\b\w/g, l => l.toUpperCase());
}

// Like prettify(), but keeps any leading "01_"/"2-" style number as a "01. "
// prefix so the sidebar mirrors the on-disk ordering of the documents.
function prettifyKeepNum(component) {
    const m = component.match(/^([0-9]+)[_-]/);
    const prefix = m ? m[1] + '. ' : '';
    return prefix + prettify(component);
}

const HTML_ESCAPES = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' };
function escapeHtml(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, c => HTML_ESCAPES[c]); }
function cleanName(name) { return (name || '').replace(/^\s*\d+\.\s*/, ''); }

const CLOCK_ICON = '<svg class="icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 1.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8.75-4.25v3.94l2.4 2.4a.75.75 0 0 1-1.06 1.06l-2.62-2.62a.75.75 0 0 1-.22-.53V3.75a.75.75 0 0 1 1.5 0Z"></path></svg>';

TAB_DATA.forEach((tab, idx) => {
    const opt = document.createElement('option');
    opt.value = String(idx);
    opt.textContent = tab.name;
    docSelect.appendChild(opt);

    const panel = document.createElement('div');
    panel.className = 'tab-content';
    panel.id = 'panel-' + idx;
    panel.dataset.dir = tab.dir || '';
    panel.innerHTML = tab.body;

    // Breadcrumb + reading-time meta line (prepended, built once).
    const meta = document.createElement('div');
    meta.className = 'doc-meta';
    const crumbs = cleanName(tab.name).split(' / ');
    const crumbHtml = crumbs.map((c, i) =>
        '<span class="crumb">' + escapeHtml(c) + '</span>' +
        (i < crumbs.length - 1 ? '<span class="crumb-sep">/</span>' : '')
    ).join('');
    const words = (tab.words || 0).toLocaleString();
    meta.innerHTML =
        '<span class="doc-breadcrumb">' + crumbHtml + '</span>' +
        '<span class="doc-reading-time">' + CLOCK_ICON +
        (tab.mins || 1) + ' min read \u00b7 ' + words + ' words</span>';
    panel.insertBefore(meta, panel.firstChild);

    tabPanels.appendChild(panel);
});

// Build directory tree structure
const docTree = { files: [], dirs: {} };
TAB_DATA.forEach((tab, idx) => {
    const parts = (tab.path || '').split('/');
    let current = docTree;
    for (let i = 0; i < parts.length - 1; i++) {
        const dirName = parts[i];
        if (!current.dirs[dirName]) {
            current.dirs[dirName] = { files: [], dirs: {} };
        }
        current = current.dirs[dirName];
    }
    current.files.push({ tab, idx });
});

// Build HTML from tree
function createTreeHtml(node, parentPath = '') {
    const ul = document.createElement('ul');
    ul.className = 'nav-list';
    
    // Sort directories and add them
    Object.keys(node.dirs).sort().forEach(dirName => {
        const dirNode = node.dirs[dirName];
        const li = document.createElement('li');
        li.className = 'nav-dir-item expanded'; // expanded by default
        
        const header = document.createElement('div');
        header.className = 'nav-dir-header';
        
        const chevron = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
        chevron.setAttribute('class', 'icon chevron-icon');
        chevron.setAttribute('viewBox', '0 0 16 16');
        chevron.innerHTML = '<path d="M6.22 3.22a.75.75 0 0 1 1.06 0l4.25 4.25a.75.75 0 0 1 0 1.06l-4.25 4.25a.75.75 0 0 1-1.06-1.06L9.94 8 6.22 4.28a.75.75 0 0 1 0-1.06Z"></path>';
        
        const folder = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
        folder.setAttribute('class', 'icon folder-icon');
        folder.setAttribute('viewBox', '0 0 16 16');
        folder.innerHTML = '<path d="M1.75 1A1.75 1.75 0 0 0 0 2.75v10.5C0 14.216.784 15 1.75 15h12.5A1.75 1.75 0 0 0 16 13.25v-8.5A1.75 1.75 0 0 0 14.25 3H7.58L6.06 1.48A1.75 1.75 0 0 0 4.81 1H1.75Zm0 1.5h3.06c.2 0 .39.08.53.22L6.873 4.25H14.25a.25.25 0 0 1 .25.25v8.5a.25.25 0 0 1-.25.25H1.75a.25.25 0 0 1-.25-.25v-10.5a.25.25 0 0 1 .25-.25Z"></path>';
        
        const label = document.createElement('span');
        label.className = 'dir-name';
        label.textContent = prettifyKeepNum(dirName);
        
        header.appendChild(chevron);
        header.appendChild(folder);
        header.appendChild(label);
        li.appendChild(header);
        
        const childrenContainer = createTreeHtml(dirNode, parentPath ? parentPath + '/' + dirName : dirName);
        childrenContainer.className = 'nav-dir-children';
        li.appendChild(childrenContainer);
        
        header.addEventListener('click', (e) => {
            e.stopPropagation();
            li.classList.toggle('expanded');
        });
        
        ul.appendChild(li);
    });
    
    // Sort and add files
    node.files.forEach(({ tab, idx }) => {
        const li = document.createElement('li');
        const a = document.createElement('a');
        a.href = '#tab-' + idx;
        
        // Use the basename, keeping any leading "NN_" document number prefix.
        const baseName = tab.path.split('/').pop() || tab.name;
        let displayName = baseName.replace(/\.[a-zA-Z0-9]+$/, '');
        displayName = prettifyKeepNum(displayName);
        
        a.textContent = displayName;
        a.title = tab.name;
        a.dataset.docIdx = String(idx);
        a.addEventListener('click', function(e) {
            e.preventDefault();
            activateTab(idx);
        });
        li.appendChild(a);
        ul.appendChild(li);
    });
    
    return ul;
}

const treeHtml = createTreeHtml(docTree);
while (treeHtml.firstChild) {
    docList.appendChild(treeHtml.firstChild);
}

/* ───── Cross-document link resolution (supports nested folders) ─────
   Docs may live in sub-directories and link to each other with relative
   paths ("../03_patterns/README.md"), bare files ("CHEATSHEET.md") or even a
   folder ("01_pthreads/"), which we resolve to that folder's README. */
const BY_PATH = {};        // "01_pthreads/readme.md"  -> idx
const BY_DIR_README = {};  // "01_pthreads" / ""        -> idx (README of dir)
const BY_BASENAME = {};    // "cheatsheet.md"           -> idx (only if unique)
const BASENAME_DUP = {};

TAB_DATA.forEach((tab, idx) => {
    const path = (tab.path || '').toLowerCase();
    if (path) BY_PATH[path] = idx;
    const base = path.split('/').pop();
    if (base) {
        if (Object.prototype.hasOwnProperty.call(BY_BASENAME, base)) BASENAME_DUP[base] = true;
        else BY_BASENAME[base] = idx;
    }
    if (base === 'readme.md') {
        BY_DIR_README[(tab.dir || '').toLowerCase()] = idx;
    }
});
Object.keys(BASENAME_DUP).forEach(b => { delete BY_BASENAME[b]; });

/* Join a relative href onto a base directory and normalize . / .. segments. */
function joinPath(baseDir, rel) {
    if (rel.charAt(0) === '/') { baseDir = ''; rel = rel.replace(/^\/+/, ''); }
    const parts = (baseDir ? baseDir.split('/') : []).concat(rel.split('/'));
    const out = [];
    for (const p of parts) {
        if (p === '' || p === '.') continue;
        if (p === '..') { out.pop(); continue; }
        out.push(p);
    }
    return out.join('/');
}

function mdTarget(rawHref, baseDir) {
    if (!rawHref || rawHref.charAt(0) === '#') return null;
    if (/^[a-z][a-z0-9+.-]*:\/\//i.test(rawHref) || /^(mailto|tel):/i.test(rawHref)) return null;

    let anchor = '';
    let pathPart = rawHref;
    const hashIdx = pathPart.indexOf('#');
    if (hashIdx >= 0) {
        anchor = pathPart.substring(hashIdx + 1);
        pathPart = pathPart.substring(0, hashIdx);
        try { anchor = decodeURIComponent(anchor); } catch (e) {}
    }
    const qIdx = pathPart.indexOf('?');
    if (qIdx >= 0) pathPart = pathPart.substring(0, qIdx);
    if (!pathPart) return null;

    const joined = joinPath(baseDir || '', pathPart).toLowerCase();
    let idx;
    if (/\.md$/i.test(pathPart)) {
        idx = BY_PATH[joined];
        if (idx === undefined) {
            const base = joined.split('/').pop();
            idx = BY_BASENAME[base];
        }
    } else {
        // a directory reference -> that folder's README
        idx = BY_DIR_README[joined];
    }
    if (idx === undefined) return null;
    return { idx: idx, anchor: anchor };
}

function baseDirOf(node) {
    const panel = node && node.closest ? node.closest('.tab-content') : null;
    return panel ? (panel.dataset.dir || '') : '';
}

/* Tag links so we can style internal navigation distinctly from external ones. */
function classifyLinks() {
    document.querySelectorAll('.tab-content a[href]').forEach(a => {
        const href = a.getAttribute('href');
        if (!href) return;
        if (href.charAt(0) === '#') {
            a.classList.add('anchor-link');
        } else if (mdTarget(href, baseDirOf(a))) {
            a.classList.add('xref-link');
        } else if (/^[a-z][a-z0-9+.-]*:\/\//i.test(href)) {
            a.target = '_blank';
            a.rel = 'noopener noreferrer';
        }
    });
}
classifyLinks();

docSelect.addEventListener('change', () => {
    activateTab(parseInt(docSelect.value, 10));
});

/* Previous / next document buttons in the navbar. */
const docPrevBtn = document.getElementById('docPrev');
const docNextBtn = document.getElementById('docNext');
if (docPrevBtn) docPrevBtn.addEventListener('click', () => {
    const i = currentTabIdx();
    if (i > 0) { pushHistory(); activateTab(i - 1); }
});
if (docNextBtn) docNextBtn.addEventListener('click', () => {
    const i = currentTabIdx();
    if (i < TAB_DATA.length - 1) { pushHistory(); activateTab(i + 1); }
});

function updateDocNav(idx) {
    if (docPrevBtn) docPrevBtn.disabled = (idx <= 0);
    if (docNextBtn) docNextBtn.disabled = (idx >= TAB_DATA.length - 1);
}

/* ───── Syntax highlighting ───── */

function addCopyButton(pre, block) {
    const btn = document.createElement('button');
    btn.className = 'code-copy-btn';
    btn.type = 'button';
    btn.textContent = 'Copy';
    btn.addEventListener('click', () => {
        const text = block.innerText;
        const done = () => {
            btn.textContent = 'Copied';
            btn.classList.add('copied');
            setTimeout(() => { btn.textContent = 'Copy'; btn.classList.remove('copied'); }, 1600);
        };
        if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(text).then(done).catch(() => fallbackCopy(text, done));
        } else {
            fallbackCopy(text, done);
        }
    });
    pre.appendChild(btn);
}

function fallbackCopy(text, done) {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); done(); } catch (e) {}
    document.body.removeChild(ta);
}

function highlightAllCode() {
    document.querySelectorAll('.tab-content pre code').forEach(block => {
        if (block.dataset.highlighted === '1') return;
        const pre = block.closest('pre');
        const langClass = Array.from(block.classList).find(c => c.startsWith('language-'));
        if (langClass) {
            const lang = langClass.replace('language-', '');
            const label = document.createElement('span');
            label.className = 'code-lang-label';
            label.textContent = lang;
            pre.appendChild(label);
        }
        hljs.highlightElement(block);
        addCopyButton(pre, block);
        block.dataset.highlighted = '1';
    });
}

highlightAllCode();

/* ───── Wrap tables so they scroll horizontally on narrow screens ───── */
function wrapTables() {
    document.querySelectorAll('.tab-content table').forEach(table => {
        if (table.parentElement && table.parentElement.classList.contains('table-scroll')) return;
        const wrap = document.createElement('div');
        wrap.className = 'table-scroll';
        table.parentNode.insertBefore(wrap, table);
        wrap.appendChild(table);
    });
}
wrapTables();

/* ───── Theme toggle ───── */
/* - Nagesh N Nazare - */

const HLJS_DARK = 'https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/vs2015.min.css';
const HLJS_LIGHT = 'https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/vs.min.css';
const themeToggleBtn = document.getElementById('themeToggle');
const hljsLink = document.getElementById('hljs-theme');

const ICON_SUN = '<svg class="icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 12a4 4 0 1 1 0-8 4 4 0 0 1 0 8Zm0-1.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5Zm5.657-8.157a.75.75 0 0 1 0 1.061l-1.061 1.06a.749.749 0 0 1-1.275-.326.749.749 0 0 1 .215-.734l1.06-1.06a.75.75 0 0 1 1.06 0Zm-9.193 9.193a.75.75 0 0 1 0 1.06l-1.06 1.061a.75.75 0 1 1-1.061-1.06l1.06-1.061a.75.75 0 0 1 1.061 0ZM8 0a.75.75 0 0 1 .75.75v1.5a.75.75 0 0 1-1.5 0V.75A.75.75 0 0 1 8 0ZM3 8a.75.75 0 0 1-.75.75H.75a.75.75 0 0 1 0-1.5h1.5A.75.75 0 0 1 3 8Zm13 0a.75.75 0 0 1-.75.75h-1.5a.75.75 0 0 1 0-1.5h1.5A.75.75 0 0 1 16 8Zm-8 5a.75.75 0 0 1 .75.75v1.5a.75.75 0 0 1-1.5 0v-1.5A.75.75 0 0 1 8 13Zm3.536-2.464a.75.75 0 0 1 1.06 0l1.061 1.06a.75.75 0 0 1-1.06 1.061l-1.061-1.06a.75.75 0 0 1 0-1.061Zm-8.132 0a.75.75 0 0 1 1.06 1.061l-1.06 1.06a.749.749 0 0 1-1.275-.326.749.749 0 0 1 .215-.734Z"></path></svg>';
const ICON_MOON = '<svg class="icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M9.598 1.591a.749.749 0 0 1 .785-.175 7.001 7.001 0 1 1-8.967 8.967.75.75 0 0 1 .961-.96 5.5 5.5 0 0 0 7.046-7.046.75.75 0 0 1 .175-.786Zm1.616 1.945a7 7 0 0 1-7.678 7.678 5.499 5.499 0 1 0 7.678-7.678Z"></path></svg>';

function getStoredTheme() {
    try { return localStorage.getItem('doc-theme'); } catch(e) { return null; }
}

const darkMql = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
function osTheme() { return (darkMql && darkMql.matches) ? 'dark' : 'light'; }

// Apply a theme. `persist` is true ONLY for an explicit user action; auto/OS
// applications must NOT write to storage, otherwise the very first auto theme
// would look like an explicit choice and we'd stop following the OS.
function setTheme(theme, persist) {
    document.body.setAttribute('data-theme', theme);
    hljsLink.href = theme === 'light' ? HLJS_LIGHT : HLJS_DARK;
    themeToggleBtn.innerHTML = (theme === 'light' ? ICON_SUN : ICON_MOON);
    themeToggleBtn.title = theme === 'light'
        ? 'Switch to dark mode (Ctrl+Shift+L)'
        : 'Switch to light mode (Ctrl+Shift+L)';
    if (persist) {
        try { localStorage.setItem('doc-theme', theme); } catch(e) {}
    }
}

function toggleTheme() {
    const current = document.body.getAttribute('data-theme') || 'dark';
    setTheme(current === 'dark' ? 'light' : 'dark', true);
}

(function initTheme() {
    const stored = getStoredTheme();
    if (stored === 'light' || stored === 'dark') {
        setTheme(stored, false);              // explicit user choice wins
    } else {
        setTheme(osTheme(), false);           // otherwise follow the OS (live)
    }
})();

// Live-follow the OS appearance while the reader hasn't picked a theme manually.
if (darkMql) {
    const onOsChange = (e) => {
        const stored = getStoredTheme();
        if (stored !== 'light' && stored !== 'dark') {
            setTheme(e.matches ? 'dark' : 'light', false);
        }
    };
    if (darkMql.addEventListener) darkMql.addEventListener('change', onOsChange);
    else if (darkMql.addListener) darkMql.addListener(onOsChange);  // older Safari
}

themeToggleBtn.addEventListener('click', toggleTheme);

document.addEventListener('keydown', (e) => {
    if ((e.ctrlKey || e.metaKey) && e.shiftKey && e.key === 'L') {
        e.preventDefault();
        toggleTheme();
    }
});

/* ───── Tab activation ───── */
/* - Nagesh N Nazare - */

function activateTab(idx, resetScroll) {
    if (resetScroll === undefined) resetScroll = true;
    document.querySelectorAll('.tab-content').forEach(p => p.classList.remove('active'));
    document.getElementById('panel-' + idx).classList.add('active');
    docSelect.value = String(idx);
    docList.querySelectorAll('a').forEach(a => {
        a.classList.toggle('nav-doc-active', parseInt(a.dataset.docIdx, 10) === idx);
    });
    const activeLink = docList.querySelector(`a[data-doc-idx="${idx}"]`);
    if (activeLink) {
        let parent = activeLink.closest('.nav-dir-item');
        while (parent) {
            parent.classList.add('expanded');
            parent = parent.parentElement.closest('.nav-dir-item');
        }
    }
    if (window.innerWidth <= 1024) {
        sidebarNav.classList.add('collapsed');
        document.body.classList.add('sidebar-collapsed');
        const tSidebar = document.getElementById('tocSidebar');
        if (tSidebar) {
            tSidebar.classList.add('collapsed');
            document.body.classList.add('toc-collapsed');
        }
    }
    history.replaceState(null, null, '#tab-' + idx);
    if (typeof buildToc === 'function') buildToc(idx);
    // Reflect the active document's title in the condensing navbar. Use the
    // full name (including any leading number) so it matches the picker exactly.
    if (navDocTitle && TAB_DATA[idx]) {
        navDocTitle.textContent = TAB_DATA[idx].name;
    }
    if (typeof updateDocNav === 'function') updateDocNav(idx);
    // Jump back to the top when switching documents so the reader starts at
    // the beginning rather than wherever the previous doc was scrolled to.
    if (resetScroll) {
        window.scrollTo({ top: 0, behavior: 'auto' });
        document.body.classList.remove('nav-condensed');
        navLastY = 0;
    }
    LS.set('doc-last-idx', String(idx));
}

/* ───── Lightweight state persistence (no per-scroll writes) ─────
   Remembers the last document, sidebar/TOC open state and scroll position so
   reopening the file resumes where you left off. Writes happen only on tab
   switch, panel toggle and page hide -- never during scrolling. */
const LS = {
    get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch (e) {} },
};

function persistScroll() {
    LS.set('doc-last-idx', String(currentTabIdx()));
    LS.set('doc-last-y', String(Math.round(window.scrollY)));
}
window.addEventListener('pagehide', persistScroll);
document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'hidden') persistScroll();
});

/* ───── Search index: pre-extract plain text per block ───── */

const searchIndex = [];

TAB_DATA.forEach((tab, tabIdx) => {
    const tmp = document.createElement('div');
    tmp.innerHTML = tab.body;
    let currentHeading = '';

    function walk(node) {
        for (const child of node.childNodes) {
            if (child.nodeType === Node.ELEMENT_NODE) {
                const tag = child.tagName;
                if (/^H[1-6]$/.test(tag)) {
                    currentHeading = child.textContent.trim();
                }
                const text = child.textContent.trim();
                if (text.length > 0) {
                    searchIndex.push({
                        tabIdx: tabIdx,
                        tabName: tab.name,
                        heading: currentHeading,
                        text: text,
                        tag: tag
                    });
                }
                if (/^(P|LI|TD|TH|BLOCKQUOTE|PRE|H[1-6])$/.test(tag)) {
                    continue;
                }
                walk(child);
            }
        }
    }
    walk(tmp);
});

/* ───── Search overlay logic ───── */

const overlay = document.getElementById('searchOverlay');
const searchInput = document.getElementById('searchInput');
const searchTrigger = document.getElementById('searchTrigger');
const srBody = document.getElementById('srBody');
const srCount = document.getElementById('srCount');
let srActiveIdx = -1;
let srResults = [];

function openSearch() {
    overlay.classList.add('open');
    searchInput.value = '';
    searchInput.focus();
    srBody.innerHTML = '<div class="sr-empty">Type to search across all tabs</div>';
    srCount.textContent = '';
    srActiveIdx = -1;
    srResults = [];
}

function closeSearch() {
    overlay.classList.remove('open');
    searchInput.value = '';
}

searchTrigger.addEventListener('click', openSearch);

overlay.addEventListener('click', (e) => {
    if (e.target === overlay) closeSearch();
});

document.addEventListener('keydown', (e) => {
    if ((e.ctrlKey || e.metaKey) && e.key === 'k') {
        e.preventDefault();
        if (overlay.classList.contains('open')) closeSearch();
        else openSearch();
        return;
    }
    if (e.key === '/' && !overlay.classList.contains('open') &&
        !['INPUT','TEXTAREA','SELECT'].includes(document.activeElement.tagName)) {
        e.preventDefault();
        openSearch();
        return;
    }
    if (e.key === 'Escape' && overlay.classList.contains('open')) {
        closeSearch();
        return;
    }
    if (overlay.classList.contains('open')) {
        if (e.key === 'ArrowDown') {
            e.preventDefault();
            if (srResults.length > 0) {
                srActiveIdx = Math.min(srActiveIdx + 1, srResults.length - 1);
                updateActiveResult();
            }
        } else if (e.key === 'ArrowUp') {
            e.preventDefault();
            if (srResults.length > 0) {
                srActiveIdx = Math.max(srActiveIdx - 1, 0);
                updateActiveResult();
            }
        } else if (e.key === 'Enter') {
            e.preventDefault();
            if (srActiveIdx >= 0 && srActiveIdx < srResults.length) {
                navigateToResult(srResults[srActiveIdx]);
            }
        }
    }
});

function updateActiveResult() {
    srBody.querySelectorAll('.sr-item').forEach((el, i) => {
        el.classList.toggle('sr-active', i === srActiveIdx);
    });
    const active = srBody.querySelector('.sr-active');
    if (active) active.scrollIntoView({ block: 'nearest' });
}

function escapeRegex(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

function highlightSnippet(text, query, maxLen) {
    const lower = text.toLowerCase();
    const qLower = query.toLowerCase();
    const pos = lower.indexOf(qLower);
    if (pos < 0) return text.substring(0, maxLen);

    const pad = Math.floor((maxLen - query.length) / 2);
    let start = Math.max(0, pos - pad);
    let end = Math.min(text.length, pos + query.length + pad);
    let snippet = text.substring(start, end);
    if (start > 0) snippet = '...' + snippet;
    if (end < text.length) snippet = snippet + '...';

    const re = new RegExp('(' + escapeRegex(query) + ')', 'gi');
    return snippet.replace(re, '<mark>$1</mark>');
}

let searchTimer = null;
searchInput.addEventListener('input', () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(runSearch, 120);
});

function runSearch() {
    const query = searchInput.value.trim();
    if (query.length < 2) {
        srBody.innerHTML = '<div class="sr-empty">Type at least 2 characters</div>';
        srCount.textContent = '';
        srResults = [];
        srActiveIdx = -1;
        return;
    }

    const qLower = query.toLowerCase();
    const matches = [];
    const seen = new Set();

    for (const entry of searchIndex) {
        if (entry.text.toLowerCase().includes(qLower)) {
            const key = entry.tabIdx + ':' + entry.heading + ':' + entry.text.substring(0, 80);
            if (seen.has(key)) continue;
            seen.add(key);
            matches.push(entry);
            if (matches.length >= 100) break;
        }
    }

    srResults = matches;
    srActiveIdx = matches.length > 0 ? 0 : -1;

    if (matches.length === 0) {
        srBody.innerHTML = '<div class="sr-empty">No results for "' +
            query.replace(/</g,'&lt;') + '"</div>';
        srCount.textContent = '0 results';
        return;
    }

    srCount.textContent = matches.length >= 100 ? '100+ results' : matches.length + ' result' + (matches.length > 1 ? 's' : '');

    let html = '';
    matches.forEach((m, i) => {
        const snippet = highlightSnippet(m.text, query, 160);
        html += '<div class="sr-item' + (i === 0 ? ' sr-active' : '') + '" data-ridx="' + i + '">';
        html += '<div class="sr-item-tab">' + m.tabName + '</div>';
        if (m.heading) html += '<div class="sr-item-heading">' + m.heading.replace(/</g,'&lt;') + '</div>';
        html += '<div class="sr-item-snippet">' + snippet + '</div>';
        html += '</div>';
    });
    srBody.innerHTML = html;

    srBody.querySelectorAll('.sr-item').forEach(el => {
        el.addEventListener('click', () => {
            const idx = parseInt(el.dataset.ridx, 10);
            navigateToResult(srResults[idx]);
        });
    });
}

function navigateToResult(result) {
    const savedQuery = searchInput.value.trim() || result.text.substring(0, 20);
    pushHistory();
    closeSearch();
    activateTab(result.tabIdx, false);

    requestAnimationFrame(() => {
        clearHighlights();
        const panel = document.getElementById('panel-' + result.tabIdx);
        const qLower = savedQuery.toLowerCase();
        const qLen = savedQuery.length;

        const hits = [];
        const walker = document.createTreeWalker(panel, NodeFilter.SHOW_TEXT);
        while (walker.nextNode()) {
            const node = walker.currentNode;
            const idx = node.textContent.toLowerCase().indexOf(qLower);
            if (idx >= 0) {
                hits.push({ node: node, offset: idx });
            }
        }

        let firstMark = null;
        for (let i = hits.length - 1; i >= 0; i--) {
            const h = hits[i];
            const range = document.createRange();
            range.setStart(h.node, h.offset);
            range.setEnd(h.node, h.offset + qLen);
            const mark = document.createElement('span');
            mark.className = 'search-highlight';
            mark.dataset.searchHighlight = '1';
            try { range.surroundContents(mark); firstMark = mark; } catch(e) {}
        }

        if (firstMark) {
            firstMark.scrollIntoView({ behavior: 'smooth', block: 'center' });
        }

        setTimeout(clearHighlights, 6000);
    });
}

function clearHighlights() {
    document.querySelectorAll('[data-search-highlight]').forEach(el => {
        const parent = el.parentNode;
        parent.replaceChild(document.createTextNode(el.textContent), el);
        parent.normalize();
    });
}

/* ───── Sidebar TOC + scroll spy ───── */
/* - Nagesh N Nazare - */

const sidebarNav = document.getElementById('sidebarNav');
const navList = document.getElementById('navList');
const sidebarToggle = document.getElementById('sidebarToggle');
const readProgress = document.getElementById('readProgress');
const toTopBtn = document.getElementById('toTop');
let currentTocHeadings = [];

function buildToc(panelIdx) {
    navList.innerHTML = '';
    currentTocHeadings = [];
    const panel = document.getElementById('panel-' + panelIdx);
    if (!panel) return;
    const headings = panel.querySelectorAll('h1, h2, h3, h4');
    headings.forEach((h, i) => {
        if (!h.id) h.id = 'autoid-' + panelIdx + '-' + i;
        // Capture the clean heading text once (before any permalink anchor is
        // added) so the TOC label never picks up the trailing '#'.
        let title = h.getAttribute('data-title');
        if (title === null) {
            title = h.textContent;
            h.setAttribute('data-title', title);
            // Add a hover-revealed permalink anchor (built lazily, only for the
            // doc currently being viewed).
            const perma = document.createElement('a');
            perma.className = 'heading-anchor';
            perma.href = '#' + h.id;
            perma.textContent = '#';
            perma.setAttribute('aria-label', 'Copy link to this section');
            perma.title = 'Copy link to this section';
            const headingId = h.id;
            perma.addEventListener('click', function(e) {
                e.preventDefault();
                // Keep the doc-content click handler from also firing (it would
                // re-run scroll/history logic and resolve duplicate ids).
                e.stopPropagation();
                const url = location.href.split('#')[0] + '#' + headingId;
                const flash = function() {
                    perma.classList.remove('copied');
                    // Force reflow so the animation restarts on rapid clicks.
                    void perma.offsetWidth;
                    perma.classList.add('copied');
                    setTimeout(function() { perma.classList.remove('copied'); }, 1400);
                };
                if (navigator.clipboard && navigator.clipboard.writeText) {
                    navigator.clipboard.writeText(url).then(flash).catch(function() { fallbackCopy(url, flash); });
                } else {
                    fallbackCopy(url, flash);
                }
                history.replaceState(null, '', '#' + headingId);
                scrollToTarget(h);
            });
            h.appendChild(perma);
        }
        const level = h.tagName.substring(1);
        const li = document.createElement('li');
        const a = document.createElement('a');
        a.href = '#' + h.id;
        a.textContent = title;
        a.className = 'nav-h' + level;
        a.title = title;
        a.dataset.headingId = h.id;
        a.addEventListener('click', function(e) {
            e.preventDefault();
            h.scrollIntoView({ behavior: 'smooth', block: 'start' });
        });
        li.appendChild(a);
        navList.appendChild(li);
        currentTocHeadings.push({ el: h, link: a });
    });
    updateScrollSpy();
}

/* Single rAF-throttled scroll handler drives scroll-spy, the reading-progress
   bar and the back-to-top button -- one listener doing all the work keeps
   scrolling smooth (no extra runtime over the original two listeners). */
let spyRaf = null;
function updateScrollSpy() {
    if (spyRaf) return;
    spyRaf = requestAnimationFrame(() => {
        spyRaf = null;
        const scrollY = window.scrollY;

        // Reading progress + back-to-top (run regardless of TOC contents).
        const max = document.documentElement.scrollHeight - window.innerHeight;
        const pct = max > 0 ? Math.min(100, (scrollY / max) * 100) : 0;
        if (readProgress) readProgress.style.width = pct + '%';
        if (toTopBtn) toTopBtn.classList.toggle('show', scrollY > 480);

        if (currentTocHeadings.length === 0) return;
        const offset = 80;
        let activeEntry = currentTocHeadings[0];
        for (const entry of currentTocHeadings) {
            if (entry.el.offsetTop <= scrollY + offset) {
                activeEntry = entry;
            } else {
                break;
            }
        }
        currentTocHeadings.forEach(e => e.link.classList.remove('nav-active'));
        if (activeEntry) {
            // Only update the highlight. Do NOT programmatically scroll either
            // sidebar -- they should stay put and move only when the user
            // scrolls them. (The previous code scrolled the wrong sidebar, the
            // left document list, which made it jump to the top on every click.)
            activeEntry.link.classList.add('nav-active');
        }
    });
}

/* ───── iOS-style condensing navbar (hide on scroll down, show on scroll up) ───── */
function updateNavCondense() {
    const y = window.scrollY;
    const NAV_TOP = 8;       // always expanded near the very top
    const NAV_TRIGGER = 72;  // must scroll past this before condensing
    const DELTA = 5;         // ignore tiny jitters
    if (y <= NAV_TOP) {
        document.body.classList.remove('nav-condensed');
    } else if (y > navLastY + DELTA && y > NAV_TRIGGER) {
        document.body.classList.add('nav-condensed');   // scrolling down
    } else if (y < navLastY - DELTA) {
        document.body.classList.remove('nav-condensed'); // scrolling up
    }
    navLastY = y;
}

/* One scroll listener for everything (was two). */
window.addEventListener('scroll', function () {
    updateNavCondense();
    updateScrollSpy();
}, { passive: true });

if (toTopBtn) {
    toTopBtn.addEventListener('click', function () {
        window.scrollTo({ top: 0, behavior: 'smooth' });
    });
}

const tocSidebar = document.getElementById('tocSidebar');
const tocToggle = document.getElementById('tocToggle');

function toggleSidebar() {
    const collapsed = sidebarNav.classList.toggle('collapsed');
    document.body.classList.toggle('sidebar-collapsed', collapsed);
    if (!collapsed && window.innerWidth <= 1024) {
        tocSidebar.classList.add('collapsed');
        document.body.classList.add('toc-collapsed');
    }
    LS.set('doc-sidebar', collapsed ? 'closed' : 'open');
}

function toggleToc() {
    const collapsed = tocSidebar.classList.toggle('collapsed');
    document.body.classList.toggle('toc-collapsed', collapsed);
    if (!collapsed && window.innerWidth <= 1024) {
        sidebarNav.classList.add('collapsed');
        document.body.classList.add('sidebar-collapsed');
    }
    LS.set('doc-toc', collapsed ? 'closed' : 'open');
}

sidebarToggle.addEventListener('click', toggleSidebar);
tocToggle.addEventListener('click', toggleToc);

document.addEventListener('click', (e) => {
    if (window.innerWidth <= 1024) {
        if (!sidebarNav.contains(e.target) && !tocSidebar.contains(e.target) &&
            !sidebarToggle.contains(e.target) && !tocToggle.contains(e.target)) {
            sidebarNav.classList.add('collapsed');
            document.body.classList.add('sidebar-collapsed');
            tocSidebar.classList.add('collapsed');
            document.body.classList.add('toc-collapsed');
        }
    }
});

document.addEventListener('keydown', (e) => {
    if ((e.ctrlKey || e.metaKey) && e.key === 'b' && !overlay.classList.contains('open')) {
        e.preventDefault();
        toggleSidebar();
    }
    if ((e.ctrlKey || e.metaKey) && e.key === 'i' && !overlay.classList.contains('open')) {
        e.preventDefault();
        toggleToc();
    }
});

/* ───── Anchor + cross-document link interception ───── */

/* Find an element by id, preferring the given panel (heading ids can collide
   across documents because each file is converted independently). */
function findById(id, preferredPanel) {
    if (preferredPanel) {
        const scoped = preferredPanel.querySelector('[id="' + id.replace(/(["\\])/g, '\\$1') + '"]');
        if (scoped) return scoped;
    }
    return document.getElementById(id);
}

function scrollToTarget(target) {
    requestAnimationFrame(() => target.scrollIntoView({ behavior: 'smooth', block: 'start' }));
}

function gotoAnchor(idx, anchor) {
    activateTab(idx, !anchor);
    const panel = document.getElementById('panel-' + idx);
    if (anchor) {
        const target = findById(anchor, panel);
        if (target) { scrollToTarget(target); return; }
    }
}

/* ───── Navigation history (browser-style back button) ─────
   Whenever a link takes the reader to another section/document, remember where
   they were (which tab + scroll position) so the navbar back button can return
   them to exactly that spot. */
const navBackBtn = document.getElementById('navBack');
let navHistory = [];

function currentTabIdx() {
    const v = parseInt(docSelect.value, 10);
    return isNaN(v) ? 0 : v;
}

function updateBackBtn() {
    if (navBackBtn) navBackBtn.disabled = navHistory.length === 0;
}

function pushHistory() {
    navHistory.push({ idx: currentTabIdx(), y: window.scrollY });
    if (navHistory.length > 200) navHistory.shift();
    updateBackBtn();
}

function navBack() {
    const state = navHistory.pop();
    if (!state) return;
    activateTab(state.idx, false);
    // Restore the exact scroll position after the panel becomes visible.
    requestAnimationFrame(() => window.scrollTo({ top: state.y, behavior: 'auto' }));
    updateBackBtn();
}

if (navBackBtn) navBackBtn.addEventListener('click', navBack);
document.addEventListener('keydown', (e) => {
    if (e.altKey && e.key === 'ArrowLeft' && !overlay.classList.contains('open')) {
        e.preventDefault();
        navBack();
    }
});

document.addEventListener('click', function(e) {
    const link = e.target.closest('a[href]');
    if (!link) return;
    // Only handle links that live inside document content. Links in the
    // sidebars (TOC "on this page", document list) have their own handlers;
    // letting this run for them would resolve duplicate heading ids against
    // the wrong panel (every same-template doc shares the same ids).
    const ownerPanel = link.closest('.tab-content');
    if (!ownerPanel) return;
    const href = link.getAttribute('href');
    if (!href) return;

    // In-page anchor: resolve within the panel that owns the link first.
    if (href.charAt(0) === '#') {
        const id = href.substring(1);
        if (!id) return;
        const target = findById(id, ownerPanel);
        if (target) {
            e.preventDefault();
            pushHistory();
            const dest = target.closest('.tab-content');
            if (dest) {
                const m = dest.id.match(/^panel-(\d+)$/);
                if (m) activateTab(parseInt(m[1], 10), false);
            }
            scrollToTarget(target);
        }
        return;
    }

    // Cross-document link to another bundled doc (file or folder), optionally #anchor.
    const md = mdTarget(href, baseDirOf(link));
    if (md) {
        e.preventDefault();
        pushHistory();
        gotoAnchor(md.idx, md.anchor);
    }
});

/* ───── Startup ───── */
/* - Nagesh N Nazare - */

// Restore persisted sidebar / TOC open state (only on desktop, where the
// drawers don't overlay the content).
if (window.innerWidth > 1024) {
    if (LS.get('doc-sidebar') === 'open') {
        sidebarNav.classList.remove('collapsed');
        document.body.classList.remove('sidebar-collapsed');
    }
    if (LS.get('doc-toc') === 'open') {
        tocSidebar.classList.remove('collapsed');
        document.body.classList.remove('toc-collapsed');
    }
}

const hash = location.hash || '';
const tabMatch = hash.match(/^#tab-(\d+)$/);
if (tabMatch) {
    activateTab(Math.min(parseInt(tabMatch[1], 10), TAB_DATA.length - 1));
} else if (hash.length > 1) {
    const targetId = hash.substring(1);
    const target = document.getElementById(targetId);
    if (target) {
        const panels = document.querySelectorAll('.tab-content');
        for (let i = 0; i < panels.length; i++) {
            if (panels[i].contains(target)) {
                activateTab(i, false);
                requestAnimationFrame(() => {
                    target.scrollIntoView({ behavior: 'smooth', block: 'start' });
                });
                break;
            }
        }
    } else {
        activateTab(0);
    }
} else {
    // No explicit target: resume the last-read document + scroll position.
    const lastIdx = parseInt(LS.get('doc-last-idx'), 10);
    const lastY = parseInt(LS.get('doc-last-y'), 10);
    if (!isNaN(lastIdx) && lastIdx >= 0 && lastIdx < TAB_DATA.length) {
        activateTab(lastIdx, false);
        if (!isNaN(lastY) && lastY > 0) {
            requestAnimationFrame(() => window.scrollTo({ top: lastY, behavior: 'auto' }));
        }
    } else {
        activateTab(0);
    }
}
</script>

</body>
</html>'''

final_html = HTML_TEMPLATE.replace('%%TAB_DATA%%', tab_data_js).replace('%%DOC_TITLE%%', escaped_title)

with open(out_file, 'w') as f:
    f.write(final_html)

print("\n[OK] Generated: {0}".format(out_file))
print("     Open in browser: file://{0}".format(out_file))
PYTHON_SCRIPT
