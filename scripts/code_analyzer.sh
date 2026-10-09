#!/bin/bash
# ==============================================================================
# Code Repository Analyzer with Comment Markers
# ------------------------------------------------------------------------------
# Scans a repository and emits machine-readable graphs for LLM workflows.
# - Files, classes, functions with 1-based line spans (ls/le)
# - Lightweight call hints (→), structured imports, simple risk flags
# - TODO/FIXME/HACK markers as first-class nodes in the graph
# - routes (full_path with include_router prefixes joined), reactions (queue / background /
#   async hand-offs) and time_triggers (cron, celery beat, setInterval): the raw material
#   for process modelling. Per function: io_out 'database' = a write, 'reaction' = a hand-off,
#   task = a queue/scheduler entry point.
# - Schemas:
#     • model  — thin, LLM-facing (minimal tokens)
#     • tool   — rich, tool-facing (complete metadata)
#     • full   — generator's full output (debug)
#     • both   — combined JSON: {"model":..., "tool":...}
#     • duplicates — duplicate filename inventory (basename → paths)
# - Optional Markdown summary
#
# USAGE:
#   repo-knowledge.sh [OPTIONS] [DIRECTORY]
#
# OPTIONS:
#   -o, --output FILE        Output path (default: DIRECTORY/repo-analysis.json)
#   -f, --format FORMAT      Output: json | markdown | both        (default: json)
#   -s, --schema SCHEMA      Schema: model | tool | full | both | duplicates (default: model)
#   --scope FILE             Focus analysis on FILE and its import/call graph neighbors
#   --traversal MODE         Import resolution: relative | absolute (default: relative)
#   --no-gitignore           Include .gitignore-matched files (flagged with gi=true)
#   -m, --markdown           Shorthand to also generate Markdown (same as -f both)
#   -v, --verbose            Verbose progress logging to stderr
#   -h, --help               Show help and exit
#
# EXAMPLES:
#   # Thin model schema JSON to repo root
#   repo-knowledge.sh ./my-repo
#
#   # Rich tool schema with comment markers
#   repo-knowledge.sh -s tool -o ./my-repo/tool-schema.json ./my-repo
#
#   # Combined {"model","tool"} plus Markdown
#   repo-knowledge.sh -s both -f both -o ./my-repo/analysis.json ./my-repo
# 
#   # Scoped analysis with absolute traversal
#   repo-knowledge.sh --scope backend-api/app/main.py --traversal absolute ./my-repo
#
# OUTPUTS:
#   - JSON:
#       • -s model → model schema JSON at --output
#       • -s tool  → tool schema JSON at --output
#       • -s full  → full generator JSON at --output
#       • -s both  → combined JSON {"model","tool"} at --output
#       • -s duplicates → duplicate filename inventory at --output
#   - Markdown (when -m or -f both):
#       • repo-analysis.md next to --output unless overridden downstream
#
# NOTES:
#   - Progress logs go to stderr. Keep stdout clean if piping JSON.
#   - Respects .gitignore and auto-ignores common build/cache dirs.
#   - Pass --no-gitignore to include matched files (flagged with gi=true).
#   - Use --scope to emit only the seed file plus reachable imports/callers.
#   - Use --traversal absolute for repo-root module resolution (default: relative).
#   - Line spans are 1-based, inclusive.
#   - Intended languages: .py, .js, .ts, .tsx, .jsx, .sh
#   - Detects: TODO, FIXME, HACK, XXX, BUG, NOTE as graph nodes
#
# VERSION:
#   1.4.0
# ==============================================================================
set -e

VERSION="1.4.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
TARGET_DIR="."
OUTPUT_FORMAT="json"
OUTPUT_FILE=""
OUTPUT_SCHEMA="model"
VERBOSE=false
INCLUDE_MARKDOWN=false
RESPECT_GITIGNORE=true
SCOPE_FILE=""
TRAVERSAL_MODE="relative"
IGNORE_PATTERNS=""

# Helper functions
print_usage() {
    cat << EOF
Usage: $0 [OPTIONS] [DIRECTORY]

Analyze code repository structure, dependencies, and TODO/FIXME markers for LLM consumption.

OPTIONS:
    -o, --output FILE       Output file path (default: repo-analysis.json)
    -f, --format FORMAT     Output format: json, markdown, both (default: json)
    -s, --schema SCHEMA     Output schema: model, tool, full, both, duplicates (default: model)
                           model = thin schema for LLM (minimal tokens)
                           tool  = rich schema for tools (complete metadata)
                           full  = complete schema (all details)
                           both  = generate model + tool schemas
                           duplicates = filename → [paths] map (duplicates only)
    --scope FILE            Limit to FILE and files connected via imports/calls
    --ignore PATTERNS       Comma-separated list of patterns to ignore (e.g. "dist,coverage,*.log")
    --traversal MODE        Import resolution: relative | absolute (default: relative)
    --no-gitignore          Include files even if matched by .gitignore (still skips common ignores)
    -m, --markdown          Also generate markdown output
    -v, --verbose           Verbose output
    -h, --help             Show this help message

EXAMPLES:
    $0 /path/to/repo
    $0 --ignore "claude-companion-LATEST,temp" ./my-repo
    $0 -o output.json -m ./src
    $0 --schema model --output thin.json
    $0 --schema both --output analysis.json
    $0 --format both --output analysis.json
    $0 --scope backend-api/app/main.py --traversal absolute ./repo

EOF
}

log() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${GREEN}[INFO]${NC} $1" >&2
    fi
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

# Strip empty objects and arrays from JSON file
strip_empty_json() {
    local input_file="$1"
    local temp_file=$(mktemp /tmp/code_analyzer_strip_XXXXXX)

    if jq '
      def strip_empty:
        walk(
          if type == "object" then
            with_entries(select(.value != {} and .value != []))
          elif type == "array" then
            map(select(. != {} and . != []))
          else
            .
          end
        );
      strip_empty
    ' "$input_file" > "$temp_file" 2>/dev/null; then
        mv "$temp_file" "$input_file"
        return 0
    else
        rm -f "$temp_file"
        return 1
    fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -f|--format)
            OUTPUT_FORMAT="$2"
            shift 2
            ;;
        -s|--schema)
            OUTPUT_SCHEMA="$2"
            shift 2
            ;;
        --scope)
            SCOPE_FILE="$2"
            shift 2
            ;;
        --ignore)
            IGNORE_PATTERNS="$2"
            shift 2
            ;;
        --traversal)
            TRAVERSAL_MODE="$2"
            shift 2
            ;;
        --no-gitignore)
            RESPECT_GITIGNORE=false
            shift
            ;;
        -m|--markdown)
            INCLUDE_MARKDOWN=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        -*)
            error "Unknown option: $1"
            ;;
        *)
            TARGET_DIR="$1"
            shift
            ;;
    esac
done

# Validate target directory
if [ ! -d "$TARGET_DIR" ]; then
    error "Directory not found: $TARGET_DIR"
fi

TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

# Set default output file if not specified
if [ -z "$OUTPUT_FILE" ]; then
    OUTPUT_FILE="$TARGET_DIR/repo-analysis.json"
fi

# Determine if markdown should be generated
if [ "$OUTPUT_FORMAT" = "markdown" ] || [ "$OUTPUT_FORMAT" = "both" ]; then
    INCLUDE_MARKDOWN=true
fi

TRAVERSAL_MODE=$(printf '%s' "$TRAVERSAL_MODE" | tr '[:upper:]' '[:lower:]')
if [ -z "$TRAVERSAL_MODE" ]; then
    TRAVERSAL_MODE="relative"
fi

case "$TRAVERSAL_MODE" in
    relative|absolute)
        ;;
    *)
        error "Invalid traversal mode: $TRAVERSAL_MODE (expected relative or absolute)"
        ;;
esac

log "Starting repository analysis with marker extraction..."
log "Target directory: $TARGET_DIR"
log "Output file: $OUTPUT_FILE"
log "Output schema: $OUTPUT_SCHEMA"
log "Respect .gitignore: $RESPECT_GITIGNORE"
if [ -n "$SCOPE_FILE" ]; then
    log "Scope file: $SCOPE_FILE"
fi
log "Traversal mode: $TRAVERSAL_MODE"

# Create Python analyzer script inline
TEMP_ANALYZER=$(mktemp /tmp/code_analyzer_XXXXXX)
cat > "$TEMP_ANALYZER" << 'PYTHON_EOF'
import os
import sys
import json
import re
import ast
import hashlib
import textwrap
from pathlib import Path
from collections import defaultdict, deque
from datetime import datetime

ALWAYS_IGNORE = {'.git', '__pycache__', 'node_modules', '.venv', 'venv', 'dist', 'build', '.next'}
SUPPORTED_EXTENSIONS = ['.py', '.js', '.ts', '.tsx', '.jsx']

class CodeAnalyzer:
    def __init__(self, root_dir, gitignore_patterns=None, respect_gitignore=True, scope_file=None, traversal_mode='relative', extra_ignores=None):
        self.root_dir = Path(root_dir).resolve()
        self.gitignore_patterns = gitignore_patterns or []
        self.extra_ignores = extra_ignores or []
        self.respect_gitignore = respect_gitignore
        self.scope_input = scope_file
        self.scope_abs_path = None
        traversal_mode = (traversal_mode or 'relative').lower()
        self.traversal_mode = traversal_mode if traversal_mode in ('relative', 'absolute') else 'relative'
        self.files = []
        self.analysis = {}
        self.markers = []  # NEW: TODO/FIXME/HACK markers
        self.reverse_deps = defaultdict(set)
        self.forward_deps = defaultdict(set)
        self.file_id_map = {}
        self.next_id = 1
        self.marker_id = 1
        self.all_files = []
        self.duplicate_filenames = {}
        self.gitignored_paths = set()
        self.module_lookup = {}
        self.data_io = {}
        self.symbol_io = defaultdict(lambda: {'inputs': [], 'outputs': [], 'io_in': set(), 'io_out': set(), 'db_in': set(), 'db_out': set()})
        self.table_index = defaultdict(lambda: {'operations': set(), 'used_in_files': set(), 'used_in_symbols': set(), 'layers': set()})
        self.orm_models = {}
        self.env_index = defaultdict(lambda: {'files': set(), 'symbols': set()})
        self.routes = []
        self.file_graph = {}
        self.symbol_index = {}
        self.class_methods = defaultdict(lambda: defaultdict(dict))  # file -> class -> method -> symbol_id
        self.module_symbol_map = defaultdict(dict)
        self.symbol_name_lookup = defaultdict(set)
        self.symbol_calls = defaultdict(set)
        self.symbol_called_by = defaultdict(set)
        self.env_index = defaultdict(lambda: {'files': set(), 'symbols': set()})
        self.routes = []
        self.reactions = []       # work handed to a queue / background task / event loop: policy candidates
        self.time_triggers = []   # cron, celery beat, scheduler jobs, setInterval: time-trigger candidates
        
    def should_ignore(self, path):
        """Check if path should be ignored; still records gitignored paths."""
        try:
            rel_path = str(path.relative_to(self.root_dir))
        except ValueError:
            rel_path = str(path)
        
        if any(part in ALWAYS_IGNORE for part in path.parts):
            return True
        
        rel_path_str = str(rel_path)
        for pattern in self.extra_ignores:
            if self._matches_gitignore(rel_path_str, pattern):
                return True
        
        gitignored = False
        for pattern in self.gitignore_patterns:
            if self._matches_gitignore(rel_path, pattern):
                gitignored = True
                break
        
        if gitignored:
            self.gitignored_paths.add(str(path))
        
        if self.respect_gitignore and gitignored:
            return True
        
        return False
    
    def _matches_gitignore(self, path, pattern):
        """Simple gitignore pattern matching"""
        pattern = pattern.strip()
        if not pattern or pattern.startswith('#'):
            return False
        
        if pattern.startswith('!'):
            return False
        
        pattern = pattern.rstrip('/')
        pattern = pattern.replace('.', r'\.')
        pattern = pattern.replace('*', r'[^/]*')
        pattern = pattern.replace('?', r'.')
        
        if '/' in pattern:
            return re.match(f"^{pattern}", path) is not None
        else:
            return re.search(f"(^|/){pattern}($|/)", path) is not None

    def _module_from_relpath(self, rel_path):
        rel = rel_path.replace(os.sep, '.')
        if rel.endswith('.__init__'):
            rel = rel[:-len('.__init__')]
        if '.' in rel:
            rel = rel.rsplit('.', 1)[0]
        return rel

    def _infer_layer_component(self, rel_path):
        parts = rel_path.split(os.sep)
        layer_candidates = ['backend-api', 'bot-engine', 'shared', 'dashboard', 'backend', 'frontend']
        component_candidates = ['backtesting', 'strategies', 'core', 'database', 'data', 'api', 'service', 'models', 'schemas']
        layer = next((p for p in parts if p in layer_candidates), None)
        component = next((p for p in parts if p in component_candidates), None)
        return layer, component

    def _truncate_list(self, items, limit=64):
        if not isinstance(items, list):
            return items
        if len(items) <= limit:
            return items
        return items[:limit]

    def _looks_configy(self, name):
        if not name:
            return False
        name = name.lower()
        keywords = [
            'lookback', 'window', 'period', 'days', 'hours', 'timeout', 'interval',
            'limit', 'max_', 'min_', 'threshold', 'cooldown', 'retry', 'batch_size',
            'num_trades', 'max_positions', 'ttl', 'cache', 'delay', 'frequency', 'retries'
        ]
        return any(k in name for k in keywords)

    def _is_secret_string(self, s):
        if not isinstance(s, str):
            return False
        prefixes = ('ghp_', 'AKIA', 'AIza', 'xoxb-', 'xoxp-', 'Bearer ')
        if any(s.startswith(p) for p in prefixes):
            return True
        if len(s) >= 32 and re.fullmatch(r'[A-Za-z0-9+/=]+', s):
            return True
        return False

    def _is_config_literal(self, s):
        if not isinstance(s, str):
            return False
        stripped = s.strip()
        if 'http://' in s or 'https://' in s:
            return True
        if ('/' in s or '\\' in s) and '://' not in s:
            parts = re.split(r'[\\/]+', s)
            if parts and re.match(r'^[\\w\\.-]+$', parts[-1] or ''):
                return False
        if '%' in s or '{' in s:
            # Skip common format strings to reduce noise
            if re.search(r'%\\.?\\d*[a-zA-Z]', s) or re.search(r'{[^}]*}', s):
                return False
        if re.search(r'\b[\w\.-]+\.[A-Za-z]{2,}\b', s):
            return True
        if any(token in s for token in (':5432', ':3306', 'user=', 'password=', 'dbname=')):
            return True
        if '\n' in stripped or len(stripped) > 120:
            return False
        return False

    def _is_magic_number(self, value):
        if not isinstance(value, (int, float)):
            return False
        if value in (0, 1, -1, 2, 10):
            return False
        return True

    def _compute_complexity(self, node):
        cyclomatic = 1
        for n in ast.walk(node):
            if isinstance(n, (ast.If, ast.For, ast.AsyncFor, ast.While, ast.Try, ast.ExceptHandler, ast.With, ast.AsyncWith)):
                cyclomatic += 1
            elif isinstance(n, ast.BoolOp):
                cyclomatic += max(len(getattr(n, 'values', [])) - 1, 0)
        loc = None
        if hasattr(node, 'lineno') and hasattr(node, 'end_lineno'):
            loc = max(1, (node.end_lineno or node.lineno) - node.lineno + 1)
        elif hasattr(node, 'lineno'):
            loc = 1
        return {'loc': loc, 'cyclomatic': cyclomatic}

    def scan_hardcoded_values(self, tree):
        """Detect hardcoded secrets/config/magic numbers/config-like defaults with context."""
        findings = []
        parent = {}
        handled_constants = set()

        for node in ast.walk(tree):
            for child in ast.iter_child_nodes(node):
                parent[child] = node

        def scope_of(node):
            cur = node
            while cur in parent:
                cur = parent[cur]
                if isinstance(cur, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    return 'function', getattr(cur, 'name', None)
                if isinstance(cur, ast.ClassDef):
                    return 'class', getattr(cur, 'name', None)
            return 'module', None

        def short_name(target):
            if isinstance(target, ast.Name):
                return target.id
            if isinstance(target, ast.Attribute):
                base = short_name(target.value)
                return f"{base}.{target.attr}" if base else target.attr
            if isinstance(target, ast.Subscript):
                return short_name(target.value)
            return None

        def binding_for(node):
            p = parent.get(node)
            names = []
            binding_kind = None
            if isinstance(p, ast.Assign):
                names = [short_name(t) for t in p.targets if short_name(t)]
                binding_kind = 'assignment'
            elif isinstance(p, ast.AnnAssign):
                tgt = getattr(p, 'target', None)
                name = short_name(tgt) if tgt else None
                names = [name] if name else []
                binding_kind = 'assignment'
            elif isinstance(p, ast.AugAssign):
                name = short_name(getattr(p, 'target', None))
                names = [name] if name else []
                binding_kind = 'assignment'
            elif isinstance(p, ast.arg):
                names = [p.arg]
                binding_kind = 'default_arg'
            elif isinstance(p, ast.keyword):
                if p.arg:
                    names = [p.arg]
                binding_kind = 'keyword_arg'
            return [n for n in names if n], binding_kind

        def context_of(node):
            p = parent.get(node)
            if isinstance(p, (ast.Assign, ast.AnnAssign, ast.AugAssign)):
                return 'assignment'
            if isinstance(p, ast.arg):
                return 'default_arg'
            if isinstance(p, ast.keyword):
                return 'keyword_arg'
            if isinstance(p, ast.Return):
                return 'return'
            if isinstance(p, ast.Call):
                return 'call_arg'
            if isinstance(p, (ast.Compare, ast.If, ast.While, ast.BoolOp)):
                return 'condition'
            if isinstance(p, (ast.For, ast.AsyncFor, ast.comprehension)):
                return 'loop'
            if isinstance(p, ast.Subscript):
                return 'subscript'
            return 'literal'

        def add_entry(kind, node, value, name=None, context=None, binding=None, scope=None, role=None):
            entry = {
                'kind': kind,
                'value': str(value)[:200],
                'ls': getattr(node, 'lineno', 1),
                'le': getattr(node, 'end_lineno', getattr(node, 'lineno', 1))
            }
            if name:
                entry['name'] = name
            if context:
                entry['context'] = context
            if binding:
                entry['binding'] = binding
            if scope:
                entry['scope'] = scope
            if role:
                entry['role'] = role
            findings.append(entry)

        def mark_config_assignment(val_node, targets):
            scope_kind, scope_name = scope_of(val_node)
            binding_names = [t for t in targets if t]
            add_entry(
                'config_like',
                val_node,
                val_node.value if isinstance(val_node, ast.Constant) else None,
                name=binding_names[0] if binding_names else None,
                context='assignment',
                binding=binding_names,
                scope=f"{scope_kind}{':' + scope_name if scope_name else ''}",
                role='config_assignment'
            )
            handled_constants.add(id(val_node))

        # Config-like assignments at module/class level with binding context
        for node in ast.walk(tree):
            if isinstance(node, (ast.Assign, ast.AnnAssign)):
                targets = node.targets if isinstance(node, ast.Assign) else [node.target]
                val = getattr(node, 'value', None)
                target_names = [short_name(t) for t in targets if short_name(t)]
                if isinstance(val, ast.Constant) and any(self._looks_configy(t) for t in target_names):
                    mark_config_assignment(val, target_names)

        # Function default args config_like (capture binding)
        for fn in ast.walk(tree):
            if isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)):
                defaults = list(fn.args.defaults or [])
                args = list(fn.args.args or [])
                if defaults:
                    offset = len(args) - len(defaults)
                    for i, default in enumerate(defaults):
                        if isinstance(default, ast.Constant):
                            arg = args[offset + i]
                            if self._looks_configy(arg.arg):
                                scope_kind, scope_name = scope_of(default)
                                add_entry(
                                    'config_like',
                                    default,
                                    default.value,
                                    name=arg.arg,
                                    context='default_arg',
                                    binding=[arg.arg],
                                    scope=f"{scope_kind}{':' + scope_name if scope_name else ''}",
                                    role='config_assignment'
                                )
                                handled_constants.add(id(default))

        # General constants for secrets/config literals/magic numbers with richer context
        for node in ast.walk(tree):
            if not isinstance(node, ast.Constant):
                continue
            if id(node) in handled_constants:
                continue
            val = node.value
            ctx = context_of(node)
            bindings, binding_kind = binding_for(node)
            scope_kind, scope_name = scope_of(node)
            scope_label = f"{scope_kind}{':' + scope_name if scope_name else ''}"
            upper_binding = binding_kind == 'assignment' and any(name.isupper() for name in bindings)

            if isinstance(val, str):
                if self._is_secret_string(val):
                    add_entry('secret', node, val, context=ctx, binding=bindings, scope=scope_label, role=binding_kind or ctx)
                elif self._is_config_literal(val):
                    add_entry('config_literal', node, val, context=ctx, binding=bindings, scope=scope_label, role=binding_kind or ctx)
            elif self._is_magic_number(val):
                if upper_binding:
                    continue
                if any(self._looks_configy(name) for name in bindings):
                    continue
                add_entry('magic_number', node, val, context=ctx, binding=bindings, scope=scope_label, role=binding_kind or ctx)

        return findings[:20] if len(findings) > 20 else findings

    def _looks_configy_literal_target(self, targets):
        for tgt in targets:
            if isinstance(tgt, ast.Name) and self._looks_configy(tgt.id):
                return True
        return False

    def scan_hardcoded_values_js(self, content, file_path):
        """Detect hardcoded secrets/config/magic numbers in JS/TS files using regex"""
        findings = []
        lines = content.split('\n')

        def add_entry(kind, line_num, value, name=None, context=None):
            entry = {
                'kind': kind,
                'value': str(value)[:200],
                'ls': line_num,
                'le': line_num
            }
            if name:
                entry['name'] = name
            if context:
                entry['context'] = context
            findings.append(entry)

        # Secret patterns
        secret_patterns = [
            (r'[\'"`]ghp_[A-Za-z0-9]{36}[\'"`]', 'github_token'),
            (r'[\'"`]AKIA[A-Z0-9]{16}[\'"`]', 'aws_key'),
            (r'[\'"`]AIza[A-Za-z0-9_-]{35}[\'"`]', 'google_api_key'),
            (r'[\'"`]xox[baprs]-[A-Za-z0-9-]+[\'"`]', 'slack_token'),
            (r'[\'"`]sk-[A-Za-z0-9]{48}[\'"`]', 'openai_key'),
            (r'[\'"`]Bearer\s+[A-Za-z0-9._-]+[\'"`]', 'bearer_token'),
            (r'(?:api[_-]?key|apikey|secret|password|token)\s*[=:]\s*[\'"`]([^\'"`]{8,})[\'"`]', 'secret_assignment'),
        ]

        for line_num, line in enumerate(lines, 1):
            for pattern, kind in secret_patterns:
                if re.search(pattern, line, re.I):
                    match = re.search(pattern, line, re.I)
                    if match:
                        add_entry('secret', line_num, match.group(0)[:50] + '...', context=kind)

        # Config-like constants (SCREAMING_SNAKE_CASE or camelCase with config keywords)
        config_pattern = r'(?:const|let|var)\s+([A-Z][A-Z0-9_]*|[a-z]+(?:Timeout|Delay|Interval|Limit|Max|Min|Port|Host|Url|Path|Size|Count|Retries|Ttl|Duration))\s*[=:]\s*([\'"`]?[^;,\n]+[\'"`]?)'

        for line_num, line in enumerate(lines, 1):
            for match in re.finditer(config_pattern, line):
                name = match.group(1)
                value = match.group(2).strip().rstrip(';,')
                # Skip if it's a function call or complex expression
                if '(' in value and ')' in value:
                    continue
                if self._looks_configy(name):
                    add_entry('config_like', line_num, value, name=name, context='assignment')

        # URL/connection strings
        url_pattern = r'[\'"`]((?:https?|mongodb|postgres|mysql|redis|amqp)://[^\'"` ]+)[\'"`]'
        for line_num, line in enumerate(lines, 1):
            for match in re.finditer(url_pattern, line):
                add_entry('config_literal', line_num, match.group(1), context='url')

        # Magic numbers (excluding common values like 0, 1, -1, 2, 10, 100, 1000)
        # Look for numbers in assignments or comparisons that aren't trivial
        magic_pattern = r'(?<![.\w])(\d{2,}(?:\.\d+)?)\b'
        trivial_numbers = {'10', '100', '1000', '60', '24', '365', '404', '500', '200', '201', '204', '400', '401', '403'}

        for line_num, line in enumerate(lines, 1):
            # Skip import/require lines
            if re.match(r'\s*(import|require|export)', line):
                continue
            # Skip comments
            if re.match(r'\s*//', line):
                continue
            for match in re.finditer(magic_pattern, line):
                num = match.group(1)
                if num not in trivial_numbers:
                    # Check if it's in a config-like assignment
                    before = line[:match.start()]
                    name_match = re.search(r'(?:const|let|var)\s+(\w+)\s*=\s*$', before)
                    if name_match and name_match.group(1).isupper():
                        continue  # Skip UPPER_CASE constants
                    if self._looks_configy(name_match.group(1) if name_match else ''):
                        continue  # Skip config-like assignments
                    add_entry('magic_number', line_num, num, context='literal')

        # Environment variable usage (for tracking, not as hardcoded)
        env_pattern = r'process\.env\.(\w+)|process\.env\[[\'"`](\w+)[\'"`]\]'
        for line_num, line in enumerate(lines, 1):
            for match in re.finditer(env_pattern, line):
                env_name = match.group(1) or match.group(2)
                add_entry('env_reference', line_num, env_name, name=env_name, context='process.env')

        return findings[:20] if len(findings) > 20 else findings

    def load_gitignore(self):
        """Load and parse .gitignore file"""
        gitignore_path = self.root_dir / '.gitignore'
        if gitignore_path.exists():
            with open(gitignore_path, 'r') as f:
                self.gitignore_patterns = [
                    line.strip() for line in f 
                    if line.strip() and not line.startswith('#')
                ]
    
    def collect_files(self):
        """Recursively collect all relevant files"""
        extensions = set(SUPPORTED_EXTENSIONS + ['.sh'])
        self.files = []
        self.all_files = []
        self.gitignored_paths = set()
        self.module_lookup = {}
        
        for root, dirs, files in os.walk(self.root_dir):
            root_path = Path(root)
            
            dirs[:] = [d for d in dirs if not self.should_ignore(root_path / d)]
            
            for file in files:
                file_path = root_path / file
                if self.should_ignore(file_path):
                    continue
                
                self.all_files.append(file_path)
                
                if file_path.suffix in extensions:
                    self.files.append(file_path)
                    self.file_id_map[str(file_path)] = f"f{self.next_id}"
                    self.next_id += 1
                    self.register_module_aliases(file_path)
    
    def find_duplicate_filenames(self):
        """Identify duplicate basenames across all tracked files"""
        duplicates = defaultdict(list)
        
        for file_path in self.all_files:
            try:
                rel_path = str(file_path.relative_to(self.root_dir))
            except ValueError:
                rel_path = str(file_path)
            duplicates[file_path.name].append(rel_path)
        
        return {
            name: sorted(paths)
            for name, paths in duplicates.items()
            if len(paths) > 1
        }
    
    def register_module_aliases(self, file_path):
        """Register module name suffixes for absolute traversal"""
        try:
            rel_path = file_path.relative_to(self.root_dir)
        except ValueError:
            return
        if rel_path.suffix:
            rel_path = rel_path.with_suffix('')
        parts = list(rel_path.parts)
        if not parts:
            return
        for i in range(len(parts)):
            key = '.'.join(parts[i:])
            if key and key not in self.module_lookup:
                self.module_lookup[key] = file_path
    
    def resolve_scope_file(self):
        """Resolve scope file to an absolute path if provided"""
        if not self.scope_input:
            return None
        candidate = Path(self.scope_input)
        if not candidate.is_absolute():
            candidate = (self.root_dir / candidate).resolve()
        else:
            candidate = candidate.resolve()
        self.scope_abs_path = candidate
        return candidate
    
    def extract_markers(self, file_path, content):
        """
        NEW: Extract TODO, FIXME, HACK, XXX, BUG, NOTE markers from content.
        Returns list of marker dicts.
        """
        markers = []
        file_rel_path = str(file_path.relative_to(self.root_dir))
        file_id = self.file_id_map.get(str(file_path), "unknown")
        
        # Detect comment style based on file extension
        if file_path.suffix == '.py':
            comment_pattern = r'#\s*(TODO|FIXME|HACK|XXX|BUG|NOTE)\s*:?\s*(.*?)(?=\n|$)'
        elif file_path.suffix in {'.js', '.ts', '.tsx', '.jsx'}:
            comment_pattern = r'//\s*(TODO|FIXME|HACK|XXX|BUG|NOTE)\s*:?\s*(.*?)(?=\n|$)'
        elif file_path.suffix == '.sh':
            comment_pattern = r'#\s*(TODO|FIXME|HACK|XXX|BUG|NOTE)\s*:?\s*(.*?)(?=\n|$)'
        else:
            return markers
        
        for line_num, line in enumerate(content.split('\n'), 1):
            for match in re.finditer(comment_pattern, line, re.IGNORECASE):
                marker_type = match.group(1).upper()
                message = match.group(2).strip()
                
                marker = {
                    'i': f"m{self.marker_id}",
                    't': 'marker',
                    'k': marker_type,  # TODO, FIXME, HACK, etc.
                    'msg': message[:200],  # Cap message length
                    'file': file_rel_path,
                    'file_id': file_id,
                    'ls': line_num,
                    'le': line_num
                }
                
                self.markers.append(marker)
                self.marker_id += 1
        
        return markers
    
    def analyze_python_file(self, file_path, tree=None, content=None):
        """Analyze Python file using AST"""
        try:
            if content is None:
                with open(file_path, 'r', encoding='utf-8') as f:
                    content = f.read()
            if tree is None:
                tree = ast.parse(content)
            
            imports = []
            functions = []
            classes = []
            calls = []
            
            # Extract imports
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    for alias in node.names:
                        imports.append({
                            'mod': alias.name,
                            'as': alias.asname,
                            'ls': node.lineno
                        })
                elif isinstance(node, ast.ImportFrom):
                    module = node.module or ''
                    for alias in node.names:
                        imports.append({
                            'mod': f"{module}.{alias.name}" if module else alias.name,
                            'as': alias.asname,
                            'ls': node.lineno
                        })
            
            # Extract functions
            for node in ast.walk(tree):
                if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    func_info = {
                        'i': f"{self.file_id_map[str(file_path)]}_fn{len(functions)}",
                        't': 'function',
                        'n': node.name,
                        'ls': node.lineno,
                        'le': node.end_lineno or node.lineno,
                        'p': [arg.arg for arg in node.args.args],
                        '→': [],
                        'complexity': self._compute_complexity(node)
                    }
                    
                    # Extract function calls
                    for subnode in ast.walk(node):
                        if isinstance(subnode, ast.Call):
                            if isinstance(subnode.func, ast.Name):
                                cname = subnode.func.id
                                if not self._is_noise_call(cname):
                                    func_info['→'].append(cname)
                            elif isinstance(subnode.func, ast.Attribute):
                                cname = self._get_attr_name(subnode.func)
                                if not self._is_noise_call(cname):
                                    func_info['→'].append(cname)

                    if func_info['→']:
                        func_info['→'] = [c for c in func_info['→'] if not self._is_noise_call(c)]
                    
                    functions.append(func_info)
            
            # Extract classes
            for node in ast.walk(tree):
                if isinstance(node, ast.ClassDef):
                    class_info = {
                        'i': f"{self.file_id_map[str(file_path)]}_cls{len(classes)}",
                        't': 'class',
                        'n': node.name,
                        'ls': node.lineno,
                        'le': node.end_lineno or node.lineno,
                        'b': [self._get_attr_name(base) for base in node.bases],
                        'mc': sum(1 for n in node.body if isinstance(n, ast.FunctionDef))
                    }
                    classes.append(class_info)
            
            return imports, functions, classes
            
        except Exception as e:
            return [], [], []
    
    def _get_attr_name(self, node):
        """Get full attribute name from AST node"""
        if isinstance(node, ast.Name):
            return node.id
        elif isinstance(node, ast.Attribute):
            return f"{self._get_attr_name(node.value)}.{node.attr}"
        elif isinstance(node, ast.Call):
            return self._get_attr_name(node.func)
        elif isinstance(node, ast.Subscript):
            return self._get_attr_name(node.value)
        elif isinstance(node, ast.Constant):
            return repr(node.value)[:40]
        return '?'

    def _is_noise_call(self, name):
        """Identify calls we do not want to track in call graphs (e.g., print)."""
        return name == 'print'
    
    def analyze_js_ts_file(self, file_path):
        """Analyze JavaScript/TypeScript file using regex patterns"""
        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                content = f.read()

            lines = content.split('\n')
            imports = []
            functions = []
            classes = []

            # Extract imports (ES6, CommonJS, TypeScript type imports, re-exports, side-effects)
            import_patterns = [
                # Standard ES6 imports: import { foo } from './bar' or import foo from './bar'
                (r'import\s+(?:type\s+)?(?:{[^}]+}|\*\s+as\s+\w+|\w+(?:\s*,\s*{[^}]+})?)\s+from\s+[\'"]([^\'"]+)[\'"]', False),
                # Side-effect imports: import './styles.css'
                (r'import\s+[\'"]([^\'"]+)[\'"]', False),
                # CommonJS require: require('./foo')
                (r'require\s*\(\s*[\'"]([^\'"]+)[\'"]\s*\)', False),
                # Dynamic import: import('./foo')
                (r'import\s*\(\s*[\'"]([^\'"]+)[\'"]\s*\)', False),
                # Re-exports: export * from './module' or export { foo } from './module'
                (r'export\s+(?:\*|{[^}]+})\s+from\s+[\'"]([^\'"]+)[\'"]', True),
            ]

            for pattern, is_reexport in import_patterns:
                for match in re.finditer(pattern, content):
                    imp = {
                        'mod': match.group(1),
                        'ls': content[:match.start()].count('\n') + 1
                    }
                    if is_reexport:
                        imp['reexport'] = True
                    imports.append(imp)

            # Helper to find matching brace end
            def find_block_end(content, start_pos):
                """Find the end of a code block starting at start_pos (after opening brace)"""
                depth = 1
                i = start_pos
                in_string = None
                escape_next = False

                while i < len(content) and depth > 0:
                    char = content[i]

                    if escape_next:
                        escape_next = False
                        i += 1
                        continue

                    if char == '\\':
                        escape_next = True
                        i += 1
                        continue

                    if in_string:
                        if char == in_string:
                            in_string = None
                    elif char in '"\'`':
                        in_string = char
                    elif char == '{':
                        depth += 1
                    elif char == '}':
                        depth -= 1

                    i += 1

                return i if depth == 0 else len(content)

            # Helper to extract parameters from function signature
            def extract_params(sig):
                """Extract parameter names from function signature"""
                # Find content between parentheses
                match = re.search(r'\(([^)]*)\)', sig)
                if not match:
                    return []
                params_str = match.group(1)
                if not params_str.strip():
                    return []
                # Split by comma and extract param names (handle defaults, types)
                params = []
                for p in params_str.split(','):
                    p = p.strip()
                    if not p:
                        continue
                    # Remove type annotations (: Type), defaults (= value), destructuring
                    p = re.sub(r'\s*[=:].*$', '', p)
                    p = re.sub(r'^\.\.\.', '', p)  # rest params
                    p = p.strip()
                    if p and re.match(r'^\w+$', p):
                        params.append(p)
                return params

            # Helper to extract function calls from a code block
            def extract_calls(code_block):
                """Extract function call names from code"""
                calls = []
                # Match function calls: identifier( or identifier.method(
                call_pattern = r'(?<![.\w])(\w+(?:\.\w+)*)\s*\('
                noise_calls = {'if', 'for', 'while', 'switch', 'catch', 'function', 'return', 'throw', 'new', 'typeof', 'instanceof', 'async', 'await', 'console', 'log', 'warn', 'error', 'info', 'debug'}

                for match in re.finditer(call_pattern, code_block):
                    call_name = match.group(1)
                    # Skip noise calls and common built-ins
                    base_name = call_name.split('.')[0]
                    if base_name.lower() not in noise_calls and not call_name.startswith('console.'):
                        calls.append(call_name)

                return list(dict.fromkeys(calls))  # Dedupe while preserving order

            # Helper to compute simple complexity
            def compute_js_complexity(code_block):
                """Compute cyclomatic complexity for JS/TS code"""
                cyclomatic = 1
                # Count decision points
                patterns = [
                    r'\bif\s*\(',
                    r'\belse\s+if\s*\(',
                    r'\bfor\s*\(',
                    r'\bwhile\s*\(',
                    r'\bcase\s+',
                    r'\bcatch\s*\(',
                    r'\b\?\s*',  # ternary
                    r'\&\&',
                    r'\|\|',
                    r'\?\?',  # nullish coalescing
                ]
                for pattern in patterns:
                    cyclomatic += len(re.findall(pattern, code_block))
                return cyclomatic

            # Extract functions with full metadata
            # Pattern for standard function declarations
            func_decl_pattern = r'(?:export\s+)?(?:async\s+)?function\s+(\w+)\s*\(([^)]*)\)\s*(?::\s*[^{]+)?\s*\{'
            # Pattern for arrow functions: const name = (params) => { or const name = async (params) => {
            arrow_pattern = r'(?:export\s+)?(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s*)?\(([^)]*)\)\s*(?::\s*[^=]+)?\s*=>\s*\{?'
            # Pattern for method definitions in objects/classes
            method_pattern = r'(?:async\s+)?(\w+)\s*\(([^)]*)\)\s*(?::\s*[^{]+)?\s*\{'

            seen_functions = set()

            for match in re.finditer(func_decl_pattern, content):
                name = match.group(1)
                if name in seen_functions:
                    continue
                seen_functions.add(name)

                start_line = content[:match.start()].count('\n') + 1
                params = extract_params(match.group(0))

                # Find function body end
                brace_pos = match.end()
                end_pos = find_block_end(content, brace_pos)
                end_line = content[:end_pos].count('\n') + 1
                func_body = content[brace_pos:end_pos]

                functions.append({
                    'i': f"{self.file_id_map[str(file_path)]}_fn{len(functions)}",
                    't': 'function',
                    'n': name,
                    'ls': start_line,
                    'le': end_line,
                    'p': params,
                    '→': extract_calls(func_body),
                    'complexity': {'cyclomatic': compute_js_complexity(func_body), 'loc': end_line - start_line + 1}
                })

            for match in re.finditer(arrow_pattern, content):
                name = match.group(1)
                if name in seen_functions:
                    continue
                seen_functions.add(name)

                start_line = content[:match.start()].count('\n') + 1
                params = extract_params(match.group(0))

                # Check if it has a block body
                if '{' in match.group(0) or (match.end() < len(content) and content[match.end():match.end()+1] == '{'):
                    brace_start = content.find('{', match.start())
                    if brace_start != -1 and brace_start < match.end() + 20:
                        end_pos = find_block_end(content, brace_start + 1)
                        end_line = content[:end_pos].count('\n') + 1
                        func_body = content[brace_start:end_pos]
                    else:
                        end_line = start_line
                        func_body = ''
                else:
                    # Expression body - find end of statement
                    end_pos = content.find('\n', match.end())
                    if end_pos == -1:
                        end_pos = len(content)
                    end_line = start_line
                    func_body = content[match.end():end_pos]

                functions.append({
                    'i': f"{self.file_id_map[str(file_path)]}_fn{len(functions)}",
                    't': 'function',
                    'n': name,
                    'ls': start_line,
                    'le': end_line,
                    'p': params,
                    '→': extract_calls(func_body),
                    'complexity': {'cyclomatic': compute_js_complexity(func_body), 'loc': max(1, end_line - start_line + 1)}
                })

            # Extract classes with methods
            class_pattern = r'(?:export\s+)?(?:abstract\s+)?class\s+(\w+)(?:\s+extends\s+(\w+))?(?:\s+implements\s+[^{]+)?\s*\{'

            for match in re.finditer(class_pattern, content):
                class_name = match.group(1)
                base_class = match.group(2)
                start_line = content[:match.start()].count('\n') + 1

                # Find class body end
                brace_pos = match.end()
                end_pos = find_block_end(content, brace_pos)
                end_line = content[:end_pos].count('\n') + 1
                class_body = content[brace_pos:end_pos]

                # Count methods in class body
                method_count = len(re.findall(r'(?:async\s+)?(?:static\s+)?(?:get\s+|set\s+)?(\w+)\s*\([^)]*\)\s*(?::\s*[^{]+)?\s*\{', class_body))

                classes.append({
                    'i': f"{self.file_id_map[str(file_path)]}_cls{len(classes)}",
                    't': 'class',
                    'n': class_name,
                    'b': [base_class] if base_class else [],
                    'ls': start_line,
                    'le': end_line,
                    'mc': method_count
                })

            return imports, functions, classes

        except Exception as e:
            return [], [], []

    def _clean_sql_text(self, sql_text, limit=160):
        if sql_text is None:
            return None
        sql_text = ' '.join(sql_text.split())
        return textwrap.shorten(sql_text, width=limit, placeholder="...")

    def _extract_sql_literal(self, node):
        """Attempt to extract mostly-static SQL from ast.Constant or ast.JoinedStr"""
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return node.value
        if isinstance(node, ast.JoinedStr):
            parts = []
            for value in node.values:
                if isinstance(value, ast.Constant) and isinstance(value.value, str):
                    parts.append(value.value)
                else:
                    parts.append('{expr}')
            return ''.join(parts)
        return None

    def _normalize_table(self, name):
        if not name:
            return None
        name = name.strip().strip('`"[]')
        return name

    def _looks_like_sql(self, text):
        if not text or not isinstance(text, str):
            return False
        return re.match(r'\s*(select|insert|update|delete|create|alter|drop|with)\b', text.strip(), flags=re.I) is not None

    def _qualify_table(self, table, schema=None):
        if not table:
            return None
        if '.' in table:
            return table
        if schema:
            return f"{schema}.{table}"
        return table

    def _table_label(self, table, schema=None, database=None):
        if database and schema and table:
            return f"{database}.{schema}.{table}"
        if schema and table:
            return f"{schema}.{table}"
        return table

    def _parse_sql_metadata(self, sql_text):
        """Very lightweight SQL metadata extraction without external deps"""
        if not sql_text or not isinstance(sql_text, str):
            return {}
        sql = sql_text.strip()
        op = None
        if sql:
            op = sql.split()[0].strip().upper()
        table_matches = re.findall(r'(?:from|join|into|update|table)\s+([`"\\[]?[\w\.\-]+[`"\]]?)', sql, flags=re.I)
        tables = [self._normalize_table(t) for t in table_matches if t]
        columns = []
        select_match = re.search(r'select\s+(.+?)\s+from', sql, flags=re.I | re.S)
        if select_match:
            cols = select_match.group(1)
            columns = [c.strip().strip('`"') for c in cols.split(',') if c.strip() and '*' not in c]
        schema = None
        database = None
        if tables:
            first = tables[0]
            if first and '.' in first:
                parts = first.split('.')
                if len(parts) == 2:
                    schema, table_only = parts
                    tables[0] = table_only
                elif len(parts) >= 3:
                    database, schema, table_only = parts[-3], parts[-2], parts[-1]
                    tables[0] = table_only
        return {
            'operation': op,
            'database': database,
            'schema': schema,
            'tables': [t for t in tables if t],
            'columns': columns
        }

    def _module_from_js_relpath(self, rel_path):
        """Convert JS/TS relative path to module-like identifier"""
        # Remove extension
        rel = rel_path
        for ext in ['.tsx', '.ts', '.jsx', '.js', '.mjs']:
            if rel.endswith(ext):
                rel = rel[:-len(ext)]
                break
        # Convert path separators to dots
        rel = rel.replace(os.sep, '.').replace('/', '.')
        # Remove index suffix
        if rel.endswith('.index'):
            rel = rel[:-6]
        return rel

    def build_symbol_index(self):
        """Build module-qualified symbol index and class->method map"""
        index = {}
        class_methods = defaultdict(lambda: defaultdict(dict))

        for file_path, data in self.analysis.items():
            suffix = Path(file_path).suffix
            module = self._module_from_relpath(data.get('lc', '')) if suffix == '.py' else self._module_from_js_relpath(data.get('lc', ''))

            # Python files - use AST for accurate class/method mapping
            if suffix == '.py':
                fn_lookup = {(fn['ls'], fn['n']): fn['i'] for fn in data.get('fns', [])}
                try:
                    with open(file_path, 'r', encoding='utf-8') as f:
                        tree = ast.parse(f.read())
                except Exception:
                    continue

                def traverse(node, class_stack=None):
                    class_stack = class_stack or []
                    for child in ast.iter_child_nodes(node):
                        if isinstance(child, ast.ClassDef):
                            class_stack.append(child.name)
                            traverse(child, class_stack)
                            class_stack.pop()
                        elif isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                            sym_id = fn_lookup.get((child.lineno, child.name))
                            if sym_id:
                                if class_stack:
                                    key = f"{class_stack[-1]}.{child.name}"
                                    class_methods[file_path][class_stack[-1]][child.name] = sym_id
                                else:
                                    key = child.name
                                index[(module, key)] = sym_id
                            traverse(child, class_stack)
                        else:
                            traverse(child, class_stack)

                traverse(tree, [])

            # JS/TS files - use already extracted data
            elif suffix in {'.js', '.ts', '.tsx', '.jsx', '.mjs'}:
                # Index functions
                for fn in data.get('fns', []):
                    sym_id = fn.get('i')
                    name = fn.get('n')
                    if sym_id and name:
                        index[(module, name)] = sym_id

                # Index classes and try to associate methods
                cls_ranges = []
                for cls in data.get('cls', []):
                    cls_name = cls.get('n')
                    cls_ls = cls.get('ls', 0)
                    cls_le = cls.get('le', 0)
                    if cls_name:
                        cls_ranges.append((cls_name, cls_ls, cls_le))
                        index[(module, cls_name)] = cls.get('i')

                # Try to associate functions that fall within class line ranges as methods
                for fn in data.get('fns', []):
                    fn_ls = fn.get('ls', 0)
                    fn_name = fn.get('n')
                    sym_id = fn.get('i')
                    for cls_name, cls_ls, cls_le in cls_ranges:
                        if cls_ls < fn_ls <= cls_le:
                            # This function is inside a class
                            key = f"{cls_name}.{fn_name}"
                            index[(module, key)] = sym_id
                            class_methods[file_path][cls_name][fn_name] = sym_id
                            break

        self.symbol_index = index
        self.class_methods = class_methods
        module_symbol_map = defaultdict(dict)
        symbol_name_lookup = defaultdict(set)
        for (module, key), sym_id in index.items():
            module_symbol_map[module][key] = sym_id
            simple = key.split('.')[-1]
            symbol_name_lookup[simple].add(sym_id)
            symbol_name_lookup[key].add(sym_id)
            if module:
                symbol_name_lookup[f"{module}.{key}"].add(sym_id)
        self.module_symbol_map = module_symbol_map
        self.symbol_name_lookup = symbol_name_lookup
    
    def _resolve_call_by_name(self, call_name, module, file_path=None, current_class=None):
        """
        Fallback resolution that maps a raw call string (from →) to a symbol ID.
        Prefers matches in the same module and class before falling back to
        unique name matches across the repo.
        """
        if not call_name:
            return None
        cleaned = call_name.strip()
        if not cleaned:
            return None
        cleaned = cleaned.split('(')[0]
        cleaned = cleaned.replace('self.', '').replace('cls.', '').strip('.')
        simple = cleaned.split('.')[-1]

        if current_class and file_path:
            sym = self.class_methods.get(file_path, {}).get(current_class, {}).get(simple)
            if sym:
                return sym

        module_entries = self.module_symbol_map.get(module, {})
        for key in (cleaned, simple):
            if key in module_entries:
                return module_entries[key]
        for key, sym in module_entries.items():
            if key.endswith(f".{simple}"):
                return sym

        if '.' in cleaned:
            mod_part, key = cleaned.rsplit('.', 1)
            mod_entries = self.module_symbol_map.get(mod_part, {})
            if key in mod_entries:
                return mod_entries[key]
            sym = self.symbol_index.get((mod_part, key))
            if sym:
                return sym

        candidates = list(self.symbol_name_lookup.get(simple, []))
        if len(candidates) == 1:
            return candidates[0]
        return None
    
    def build_symbol_call_graph(self):
        """Populate sym_calls and sym_called_by for symbols"""
        if not self.symbol_index:
            self.build_symbol_index()

        self.symbol_calls = defaultdict(set)
        self.symbol_called_by = defaultdict(set)

        sym_to_class = {}
        for file_key, classes in self.class_methods.items():
            for cls_name, methods in classes.items():
                for _, sym_id in methods.items():
                    sym_to_class[sym_id] = cls_name

        for file_path, data in self.analysis.items():
            if Path(file_path).suffix != '.py':
                continue
            module = self._module_from_relpath(data.get('lc', ''))
            fn_lookup = {(fn['ls'], fn['n']): fn['i'] for fn in data.get('fns', [])}

            try:
                with open(file_path, 'r', encoding='utf-8') as f:
                    tree = ast.parse(f.read())
            except Exception:
                continue

            # Build import maps from AST for resolution
            import_aliases = {}
            from_imports = {}
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    for alias in node.names:
                        alias_name = alias.asname or alias.name.split('.')[0]
                        import_aliases[alias_name] = alias.name
                elif isinstance(node, ast.ImportFrom):
                    if node.module is None:
                        continue
                    for alias in node.names:
                        alias_name = alias.asname or alias.name
                        from_imports[alias_name] = (node.module, alias.name)

            def instance_bindings(fn_node):
                """name -> class, for parameters annotated with a class and locals assigned `Cls(...)`:
                `svc: OrderService = Depends(...)`, `svc = OrderService(session)`, `order = await Order.get()`."""
                b = {}
                a = fn_node.args
                for arg in a.posonlyargs + a.args + a.kwonlyargs:
                    if arg.annotation is not None:
                        name = self._get_attr_name(arg.annotation).split('.')[-1]
                        if name[:1].isupper():
                            b[arg.arg] = name
                for n in ast.walk(fn_node):
                    if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name):
                        v = n.value.value if isinstance(n.value, ast.Await) else n.value
                        if isinstance(v, ast.Call):
                            name = self._get_attr_name(v.func).split('.')[-1]
                            if name[:1].isupper():
                                b[n.targets[0].id] = name
                    elif isinstance(n, ast.AnnAssign) and isinstance(n.target, ast.Name):
                        name = self._get_attr_name(n.annotation).split('.')[-1]
                        if name[:1].isupper():
                            b[n.target.id] = name
                return b

            # self.<attr> -> class, from each class's __init__ (`self.repo = OrderRepository()` or a typed parameter)
            class_bindings = {}
            for cls in [n for n in ast.walk(tree) if isinstance(n, ast.ClassDef)]:
                attrs = {}
                for init in [n for n in cls.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name == '__init__']:
                    params = instance_bindings(init)
                    for n in ast.walk(init):
                        if not isinstance(n, (ast.Assign, ast.AnnAssign)):
                            continue
                        for t in (n.targets if isinstance(n, ast.Assign) else [n.target]):
                            if not (isinstance(t, ast.Attribute) and isinstance(t.value, ast.Name) and t.value.id == 'self'):
                                continue
                            v = n.value.value if isinstance(n.value, ast.Await) else n.value
                            if isinstance(v, ast.Call) and self._get_attr_name(v.func).split('.')[-1][:1].isupper():
                                attrs[t.attr] = self._get_attr_name(v.func).split('.')[-1]
                            elif isinstance(v, ast.Name) and v.id in params:
                                attrs[t.attr] = params[v.id]
                            elif isinstance(n, ast.AnnAssign) and self._get_attr_name(n.annotation).split('.')[-1][:1].isupper():
                                attrs[t.attr] = self._get_attr_name(n.annotation).split('.')[-1]
                class_bindings[cls.name] = attrs

            class_stack = []

            def resolve_call(func_node, current_class, bindings=None):
                # Direct name call
                if isinstance(func_node, ast.Name):
                    name = func_node.id
                    # from-imported symbol
                    if name in from_imports:
                        mod, orig = from_imports[name]
                        return self.symbol_index.get((mod, orig))
                    # same-module symbol
                    key = (module, name)
                    if key in self.symbol_index:
                        return self.symbol_index[key]
                    return None

                if isinstance(func_node, ast.Attribute):
                    attr = func_node.attr
                    val = func_node.value
                    # A name bound to a class instance: resolve `svc.create` to that class's method
                    bound = None
                    if isinstance(val, ast.Name) and bindings and val.id in bindings:
                        bound = bindings[val.id]
                    elif isinstance(val, ast.Attribute) and isinstance(val.value, ast.Name) and val.value.id in ('self', 'cls'):
                        bound = class_bindings.get(current_class, {}).get(val.attr)
                    if bound:
                        hits = [c for c in self.symbol_name_lookup.get(attr, []) if sym_to_class.get(c) == bound]
                        if len(hits) == 1:
                            return hits[0]
                    # self.method or cls.method
                    if isinstance(val, ast.Name):
                        vname = val.id
                        if current_class and vname in ('self', 'cls'):
                            return self.class_methods.get(file_path, {}).get(current_class, {}).get(attr)
                        if vname in import_aliases:
                            mod = import_aliases[vname]
                            return self.symbol_index.get((mod, attr))
                        if vname in from_imports:
                            mod, orig = from_imports[vname]
                            # treat as module attr if value is module alias
                            return self.symbol_index.get((mod, attr))
                        # ClassName.method static call
                        if vname in self.class_methods.get(file_path, {}):
                            return self.class_methods[file_path][vname].get(attr)
                    elif isinstance(val, ast.Attribute) and isinstance(val.value, ast.Name):
                        # handle alias.submodule.func
                        root = val.value.id
                        if root in import_aliases:
                            base = import_aliases[root]
                            if base.split('.')[-1] != val.attr:
                                mod = f"{base}.{val.attr}"
                            else:
                                mod = base
                            return self.symbol_index.get((mod, attr))
                    return None
                return None

            def walk(node):
                for child in ast.iter_child_nodes(node):
                    if isinstance(child, ast.ClassDef):
                        class_stack.append(child.name)
                        walk(child)
                        class_stack.pop()
                    elif isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                        sym_id = fn_lookup.get((child.lineno, child.name))
                        current_class = class_stack[-1] if class_stack else None
                        bindings = instance_bindings(child)
                        if sym_id:
                            # collect calls within this function only (skip nested defs)
                            def collect_calls(n):
                                for ch in ast.iter_child_nodes(n):
                                    if isinstance(ch, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                                        continue
                                    if isinstance(ch, ast.Call):
                                        target = resolve_call(ch.func, current_class, bindings)
                                        if not target:
                                            call_name = self._get_attr_name(ch.func)
                                            target = self._resolve_call_by_name(call_name, module, file_path=str(file_path), current_class=current_class)
                                        if target:
                                            self.symbol_calls[sym_id].add(target)
                                    collect_calls(ch)
                            collect_calls(child)
                        walk(child)
                    else:
                        walk(child)

            walk(tree)

        # Second pass: use lightweight → call names to fill any missing edges
        for file_path, data in self.analysis.items():
            suffix = Path(file_path).suffix
            if suffix == '.py':
                module = self._module_from_relpath(data.get('lc', ''))
            elif suffix in {'.js', '.ts', '.tsx', '.jsx', '.mjs'}:
                module = self._module_from_js_relpath(data.get('lc', ''))
            else:
                module = ''
            for fn in data.get('fns', []):
                sym_id = fn.get('i')
                if not sym_id:
                    continue
                current_calls = set(self.symbol_calls.get(sym_id, set()))
                for call_name in fn.get('→', []) or []:
                    target = self._resolve_call_by_name(call_name, module, file_path=file_path, current_class=sym_to_class.get(sym_id))
                    if target and target not in current_calls:
                        current_calls.add(target)
                if current_calls:
                    self.symbol_calls[sym_id].update(current_calls)

        # Build reverse edges
        for caller, callees in self.symbol_calls.items():
            for callee in callees:
                self.symbol_called_by[callee].add(caller)

        # Attach to function records
        for data in self.analysis.values():
            for fn in data.get('fns', []):
                fn['sym_calls'] = sorted(self.symbol_calls.get(fn['i'], []))
                fn['sym_called_by'] = sorted(self.symbol_called_by.get(fn['i'], []))
    
    def analyze_file(self, file_path):
        """Analyze a single file"""
        rel_path = str(file_path.relative_to(self.root_dir))
        file_id = self.file_id_map[str(file_path)]
        
        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                content = f.read()
                tree = None
                try:
                    tree = ast.parse(content) if file_path.suffix == '.py' else None
                except Exception:
                    tree = None
            
            # Extract markers (NEW)
            self.extract_markers(file_path, content)
            
            loc = len(content.splitlines())
            tok = len(content)
            
            # Analyze based on file type
            if file_path.suffix == '.py':
                imports, functions, classes = self.analyze_python_file(file_path, tree=tree, content=content)
            elif file_path.suffix in {'.js', '.ts', '.tsx', '.jsx'}:
                imports, functions, classes = self.analyze_js_ts_file(file_path)
            elif file_path.suffix == '.sh':
                imports, functions, classes = [], [], []
            else:
                imports, functions, classes = [], [], []
            
            # Build file analysis
            analysis = {
                'i': file_id,
                't': 'file',
                'n': file_path.name,
                'lc': rel_path,
                'ext': file_path.suffix,
                'loc': loc,
                'tok': tok,
                'u': [imp['mod'] for imp in imports],
                # 'imp_detail': imports, # Disabled to save space
                'fns': functions,
                'cls': classes,
                'fi': 0,
                '←': [],
                'imports_files': [],
                'imported_by': [],
                'data_io': {'inputs': [], 'outputs': []},
                'hardcoded_values': [],
                'env_usage': []
            }

            # Scan for hardcoded values
            if tree is not None:
                # Python: use AST-based scanning
                try:
                    analysis['hardcoded_values'] = self.scan_hardcoded_values(tree)
                except Exception:
                    analysis['hardcoded_values'] = []
            elif file_path.suffix in {'.js', '.ts', '.tsx', '.jsx', '.mjs'}:
                # JS/TS: use regex-based scanning
                try:
                    analysis['hardcoded_values'] = self.scan_hardcoded_values_js(content, file_path)
                except Exception:
                    analysis['hardcoded_values'] = []

            # Detect risks
            risks = []
            if 'eval(' in content or 'exec(' in content:
                risks.append('code_execution')
            if 'os.system' in content or 'subprocess' in content:
                risks.append('shell_execution')
            if re.search(r'password|secret|api[_-]?key', content, re.I):
                risks.append('credentials')
            
            if risks:
                analysis['r'] = risks
            
            if str(file_path) in self.gitignored_paths:
                analysis['gi'] = True
            
            self.analysis[str(file_path)] = analysis
            
        except Exception as e:
            self.analysis[str(file_path)] = {
                'i': file_id,
                't': 'file',
                'n': file_path.name,
                'lc': rel_path,
                'error': str(e)
            }
            if str(file_path) in self.gitignored_paths:
                self.analysis[str(file_path)]['gi'] = True
    
    def build_reverse_dependencies(self):
        """Second pass: build reverse dependency graph"""
        for file_path, data in self.analysis.items():
            if 'u' in data:
                for imported in data['u']:
                    resolved = self.resolve_import(imported, Path(file_path))
                    if resolved and str(resolved) in self.analysis:
                        self.reverse_deps[str(resolved)].add(file_path)
                        self.forward_deps[file_path].add(str(resolved))
        
        # Update analysis with reverse deps
        for file_path, data in self.analysis.items():
            if file_path in self.reverse_deps:
                data['←'] = [
                    self.analysis[dep]['i'] 
                    for dep in self.reverse_deps[file_path]
                    if dep in self.analysis
                ]
                data['fi'] = len(data['←'])

    def build_file_graph(self):
        """Construct file-to-file import graph with IDs"""
        graph = {}
        for file_path, data in self.analysis.items():
            imports_ids = []
            imported_by_ids = []
            for dep in self.forward_deps.get(file_path, set()):
                if dep in self.analysis:
                    imports_ids.append(self.analysis[dep]['i'])
            for dep in self.reverse_deps.get(file_path, set()):
                if dep in self.analysis:
                    imported_by_ids.append(self.analysis[dep]['i'])
            data['imports_files'] = sorted(set(imports_ids))
            data['imported_by'] = sorted(set(imported_by_ids))
            data['fi'] = len(data['imported_by'])
            graph[data['i']] = {
                'imports': data['imports_files'],
                'imported_by': data['imported_by']
            }
        self.file_graph = graph

    def build_tables_index(self):
        """Aggregate database table usage from file-level and symbol-level IO"""
        tables = defaultdict(lambda: {'operations': set(), 'used_in_files': set(), 'used_in_symbols': set(), 'layers': set()})
        write_counts = defaultdict(lambda: defaultdict(int))

        # Source 1: file-level data_io
        for file_path, data in self.analysis.items():
            file_id = data.get('i')
            layer = data.get('layer')
            if not layer:
                layer, _ = self._infer_layer_component(data.get('lc', ''))
            dio = data.get('data_io', {})
            for direction in ('inputs', 'outputs'):
                for io in dio.get(direction, []):
                    if io.get('kind') != 'database':
                        continue
                    tables_list = io.get('tables') or []
                    if not tables_list:
                        continue
                    op = io.get('operation') or 'UNKNOWN'
                    io_layer = io.get('layer') or layer
                    for table in tables_list:
                        t = tables[table]
                        t['operations'].add(op)
                        if file_id:
                            t['used_in_files'].add(file_id)
                        if io_layer:
                            t['layers'].add(io_layer)
                        if direction == 'outputs' and io_layer:
                            write_counts[table][io_layer] += 1

        # Source 2: symbol-level db_tables_in/out
        for file_path, data in self.analysis.items():
            file_id = data.get('i')
            layer = data.get('layer')
            if not layer:
                layer, _ = self._infer_layer_component(data.get('lc', ''))
            for fn in data.get('fns', []):
                sym_id = fn.get('i')
                for table in (fn.get('db_tables_in') or []):
                    t = tables[table]
                    if not t['operations']:
                        t['operations'].add('UNKNOWN')
                    if file_id:
                        t['used_in_files'].add(file_id)
                    if sym_id:
                        t['used_in_symbols'].add(sym_id)
                    if layer:
                        t['layers'].add(layer)
                for table in (fn.get('db_tables_out') or []):
                    t = tables[table]
                    if not t['operations']:
                        t['operations'].add('UNKNOWN')
                    if file_id:
                        t['used_in_files'].add(file_id)
                    if sym_id:
                        t['used_in_symbols'].add(sym_id)
                    if layer:
                        t['layers'].add(layer)
                        write_counts[table][layer] += 1

        # Promote table index to persistent attr and serializable dict
        self.table_index = tables
        tables_output = {}
        for table, info in tables.items():
            owner_layer = None
            if write_counts.get(table):
                sorted_layers = sorted(write_counts[table].items(), key=lambda x: (-x[1], x[0]))
                if sorted_layers:
                    top_layer, top_count = sorted_layers[0]
                    if top_count > 0:
                        owner_layer = top_layer
            tables_output[table] = {
                'operations': sorted(info['operations']),
                'used_in_files': sorted(info['used_in_files']),
                'used_in_symbols': sorted(info['used_in_symbols']),
                'layers': sorted(info['layers']),
                'owner_layer': owner_layer
            }
        return tables_output

    def compute_criticality(self):
        """Compute heuristic criticality score per file"""
        for file_path, data in self.analysis.items():
            score = 0
            reasons = []
            fi = data.get('fi', 0) or 0
            score += min(fi, 20) * 2
            if fi >= 10:
                reasons.append('high_fan_in')

            dio = data.get('data_io', {})
            db_inputs = [io for io in dio.get('inputs', []) if io.get('kind') == 'database']
            db_outputs = [io for io in dio.get('outputs', []) if io.get('kind') == 'database']
            if db_inputs or db_outputs:
                score += 10
                if db_outputs:
                    reasons.append('database_writes')
                else:
                    reasons.append('database_reads')

            if any(io.get('kind') == 'api' for io in dio.get('inputs', []) + dio.get('outputs', [])):
                score += 5
                reasons.append('api_io')

            tables = set()
            for io in db_inputs + db_outputs:
                for t in io.get('tables', []) or []:
                    tables.add(t)
            if len(tables) > 2:
                score += 5
                reasons.append('many_tables')

            symbol_count = len(data.get('fns', [])) + len(data.get('cls', []))
            if symbol_count > 10:
                score += 5
                reasons.append('many_symbols')

            score = max(0, min(100, score))
            data['criticality'] = {'score': score, 'reasons': reasons}

    def classify_data_io(self):
        """Classify data IO per file and per symbol; build DB table index"""
        self.data_io = {}
        self.symbol_io = defaultdict(lambda: {'inputs': [], 'outputs': [], 'io_in': set(), 'io_out': set(), 'db_in': set(), 'db_out': set()})
        self.table_index = defaultdict(lambda: {'operations': set(), 'used_in_files': set(), 'used_in_symbols': set(), 'layers': set()})
        self.orm_models = {}

        # First pass: collect ORM models
        for file_path, data in self.analysis.items():
            suffix = Path(file_path).suffix

            # Python ORM detection (SQLAlchemy)
            if suffix == '.py':
                try:
                    with open(file_path, 'r', encoding='utf-8') as f:
                        content = f.read()
                    tree = ast.parse(content)
                except Exception:
                    continue
                for node in ast.walk(tree):
                    if isinstance(node, ast.ClassDef):
                        table_name = None
                        schema = None
                        for stmt in node.body:
                            if isinstance(stmt, ast.Assign):
                                for target in stmt.targets:
                                    if isinstance(target, ast.Name) and target.id == '__tablename__':
                                        if isinstance(stmt.value, ast.Constant) and isinstance(stmt.value.value, str):
                                            table_name = stmt.value.value
                                    if isinstance(target, ast.Name) and target.id == '__table_args__' and isinstance(stmt.value, ast.Dict):
                                        for k, v in zip(stmt.value.keys, stmt.value.values):
                                            if isinstance(k, ast.Constant) and k.value == 'schema':
                                                if isinstance(v, ast.Constant) and isinstance(v.value, str):
                                                    schema = v.value
                        if table_name:
                            self.orm_models[node.name] = {
                                'table_name': table_name,
                                'schema': schema,
                                'module': self._module_from_relpath(data['lc']),
                                'file': file_path
                            }

            # JS/TS ORM detection (Prisma, TypeORM, Sequelize, Drizzle)
            elif suffix in {'.js', '.ts', '.tsx', '.jsx'}:
                try:
                    with open(file_path, 'r', encoding='utf-8') as f:
                        content = f.read()
                except Exception:
                    continue

                # Prisma schema models (from generated client usage)
                # Pattern: prisma.user.findMany(), prisma.post.create()
                for match in re.finditer(r'prisma\.(\w+)\.(?:findMany|findFirst|findUnique|create|update|delete|upsert|count|aggregate)', content):
                    model_name = match.group(1)
                    # Prisma uses pluralized/lowercased table names
                    self.orm_models[model_name] = {
                        'table_name': model_name,
                        'schema': None,
                        'orm': 'prisma',
                        'module': self._module_from_js_relpath(data['lc']),
                        'file': file_path
                    }

                # TypeORM entity detection
                # Pattern: @Entity('table_name') or @Entity()
                for match in re.finditer(r'@Entity\s*\(\s*[\'"]([^\'"]+)[\'"]\s*\)', content):
                    table_name = match.group(1)
                    # Try to find the class name after the decorator
                    class_match = re.search(r'@Entity[^}]*class\s+(\w+)', content[match.start():match.start()+500])
                    model_name = class_match.group(1) if class_match else table_name
                    self.orm_models[model_name] = {
                        'table_name': table_name,
                        'schema': None,
                        'orm': 'typeorm',
                        'module': self._module_from_js_relpath(data['lc']),
                        'file': file_path
                    }

                # Sequelize model detection
                # Pattern: Model.init({ ... }, { tableName: 'users' }) or sequelize.define('User', ...)
                for match in re.finditer(r"sequelize\.define\s*\(\s*['\"](\w+)['\"]", content):
                    model_name = match.group(1)
                    self.orm_models[model_name] = {
                        'table_name': model_name.lower() + 's',  # Sequelize convention
                        'schema': None,
                        'orm': 'sequelize',
                        'module': self._module_from_js_relpath(data['lc']),
                        'file': file_path
                    }
                for match in re.finditer(r"tableName\s*:\s*['\"](\w+)['\"]", content):
                    table_name = match.group(1)
                    self.orm_models[table_name] = {
                        'table_name': table_name,
                        'schema': None,
                        'orm': 'sequelize',
                        'module': self._module_from_js_relpath(data['lc']),
                        'file': file_path
                    }

                # Drizzle table detection
                # Pattern: export const users = pgTable('users', { ... })
                for match in re.finditer(r"(?:export\s+)?(?:const|let|var)\s+(\w+)\s*=\s*(?:pg|mysql|sqlite)Table\s*\(\s*['\"](\w+)['\"]", content):
                    var_name = match.group(1)
                    table_name = match.group(2)
                    self.orm_models[var_name] = {
                        'table_name': table_name,
                        'schema': None,
                        'orm': 'drizzle',
                        'module': self._module_from_js_relpath(data['lc']),
                        'file': file_path
                    }

                # Knex table references
                # Pattern: knex('users'), knex.from('users'), knex.table('users')
                for match in re.finditer(r"knex(?:\.(?:from|table|into))?\s*\(\s*['\"](\w+)['\"]", content):
                    table_name = match.group(1)
                    self.orm_models[table_name] = {
                        'table_name': table_name,
                        'schema': None,
                        'orm': 'knex',
                        'module': self._module_from_js_relpath(data['lc']),
                        'file': file_path
                    }

        # Second pass: classify IO
        for file_path, data in self.analysis.items():
            rel_path = data['lc']
            layer, component = self._infer_layer_component(rel_path)
            module_path = self._module_from_relpath(rel_path)
            file_ext = Path(file_path).suffix
            io_record = {'inputs': [], 'outputs': []}
            data['layer'] = layer
            data['component'] = component

            def record_io(direction, kind, node, how=None, where=None, symbol_id=None, extra=None, tables=None, operation=None, columns=None, sql_text=None, schema=None, database=None):
                if tables:
                    tables = [t for t in tables if t]
                loc = {
                    'ls': getattr(node, 'lineno', 1),
                    'le': getattr(node, 'end_lineno', getattr(node, 'lineno', 1))
                }
                entry = {
                    'kind': kind,
                    'where': where,
                    'how': how,
                    'loc': loc,
                    'layer': layer,
                    'module': module_path,
                    'component': component
                }
                if extra:
                    entry.update(extra)
                if kind == 'database':
                    if operation:
                        entry['operation'] = operation
                    if tables:
                        entry['tables'] = tables
                    if columns:
                        entry['columns'] = columns
                    if schema:
                        entry['schema'] = schema
                    if database:
                        entry['database'] = database
                    if sql_text:
                        entry['sql_snippet'] = self._clean_sql_text(sql_text)
                io_record[direction].append(entry)

                if symbol_id:
                    sym = self.symbol_io[symbol_id]
                    detail_entry = {'kind': kind, 'where': where, 'how': how, 'ls': loc['ls'], 'le': loc['le']}
                    if direction == 'inputs':
                        sym['io_in'].add(kind)
                        sym['inputs'].append(detail_entry)
                        if kind == 'database' and tables:
                            for t in tables:
                                sym['db_in'].add(t)
                    else:
                        sym['io_out'].add(kind)
                        sym['outputs'].append(detail_entry)
                        if kind == 'database' and tables:
                            for t in tables:
                                sym['db_out'].add(t)

                if kind == 'database' and tables:
                    op_key = operation or 'UNKNOWN'
                    for t in tables:
                        self.table_index[t]['operations'].add(op_key)
                        self.table_index[t]['used_in_files'].add(data['i'])
                        if symbol_id:
                            self.table_index[t]['used_in_symbols'].add(symbol_id)
                        if layer:
                            self.table_index[t]['layers'].add(layer)

            if file_ext == '.py':
                try:
                    with open(file_path, 'r', encoding='utf-8') as f:
                        content = f.read()
                    tree = ast.parse(content)
                except Exception:
                    self.data_io[file_path] = io_record
                    data['data_io'] = io_record
                    continue

                fn_map = {(fn['ls'], fn['n']): fn['i'] for fn in data.get('fns', [])}
                fn_by_id = {fn['i']: fn for fn in data.get('fns', [])}
                # Name loads and constructions in this file, for find_absences()
                names, built = set(), set()
                for n in ast.walk(tree):
                    if isinstance(n, ast.Name):
                        names.add(n.id)
                    elif isinstance(n, ast.Attribute):
                        names.add(n.attr)
                    if isinstance(n, ast.Call):
                        f = n.func
                        if isinstance(f, (ast.Name, ast.Attribute)):
                            built.add(f.id if isinstance(f, ast.Name) else f.attr)
                        if self._get_attr_name(f).rsplit('.', 1)[-1] in ('insert', 'add', 'add_all', 'merge', 'bulk_insert_mappings', 'bulk_save_objects'):
                            for a in n.args:
                                if isinstance(a, (ast.Name, ast.Attribute)):
                                    built.add(a.id if isinstance(a, ast.Name) else a.attr)
                data['_name_refs'], data['_constructed'] = names, built
                file_env_usage = []

                def get_symbol(node):
                    return fn_map.get((getattr(node, 'lineno', None), getattr(node, 'name', None)))

                def walk_function_body(fn_node):
                    stack = list(ast.iter_child_nodes(fn_node))
                    while stack:
                        cur = stack.pop()
                        if isinstance(cur, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                            continue
                        yield cur
                        stack.extend(ast.iter_child_nodes(cur))

                route_verbs = {'get', 'post', 'put', 'delete', 'patch', 'options'}
                http_client_funcs = {'requests.get', 'requests.post', 'requests.put', 'requests.delete', 'httpx.get', 'httpx.post', 'httpx.put', 'httpx.delete', 'aiohttp.ClientSession.get', 'aiohttp.ClientSession.post', 'aiohttp.ClientSession.put', 'aiohttp.ClientSession.delete'}
                csv_read_funcs = {'pandas.read_csv', 'pd.read_csv', 'read_csv', 'csv.reader', 'csv.DictReader'}
                csv_write_funcs = {'csv.writer', 'csv.DictWriter'}
                json_in_funcs = {'json.load', 'json.loads'}
                json_out_funcs = {'json.dump', 'json.dumps'}
                df_in_funcs = {'pd.DataFrame', 'pandas.DataFrame', 'DataFrame'}
                df_out_attrs = {'to_sql', 'to_parquet', 'to_json', 'to_csv'}
                db_exec_funcs = {'session.execute', 'engine.execute', 'cursor.execute', 'cursor.executemany', 'execute', 'pd.read_sql', 'pandas.read_sql', 'pd.read_sql_query', 'pd.read_sql_table', 'read_sql', 'read_sql_query', 'read_sql_table', 'run_query', 'fetch', 'fetchrow', 'fetchval', 'fetchall', 'conn.fetch', 'conn.fetchrow', 'conn.fetchval', 'conn.fetchall'}
                orm_read_funcs = {'session.query', 'select'}
                orm_write_funcs = {'update', 'delete', 'session.add', 'session.bulk_save_objects', 'session.merge', 'session.add_all'}

                def record_env(name, node, symbol_id=None):
                    if not name:
                        return
                    rec = {
                        'name': name,
                        'ls': getattr(node, 'lineno', 1),
                        'le': getattr(node, 'end_lineno', getattr(node, 'lineno', 1))
                    }
                    file_env_usage.append(rec)
                    if symbol_id:
                        self.env_index[name]['symbols'].add(symbol_id)
                    self.env_index[name]['files'].add(data['i'])

                def extract_env_from_call(call_node):
                    func_name = self._get_attr_name(call_node.func)
                    if func_name in ('os.getenv', 'os.environ.get'):
                        if call_node.args and isinstance(call_node.args[0], ast.Constant) and isinstance(call_node.args[0].value, str):
                            return call_node.args[0].value
                    return None

                def extract_env_from_subscript(sub_node):
                    if not isinstance(sub_node, ast.Subscript):
                        return None
                    target = sub_node.value
                    target_name = self._get_attr_name(target) if hasattr(self, '_get_attr_name') else None
                    if target_name and ('os.environ' in target_name or target_name.endswith('.environ') or target_name == 'environ'):
                        slice_node = sub_node.slice
                        if isinstance(slice_node, ast.Constant) and isinstance(slice_node.value, str):
                            return slice_node.value
                        if isinstance(slice_node, ast.Index) and isinstance(slice_node.value, ast.Constant) and isinstance(slice_node.value.value, str):
                            return slice_node.value.value
                    return None

                # Celery beat schedules name the task and the clock together; record them whole and
                # remember their crontab() nodes so the generic walk below does not count them twice.
                seen_time_nodes = set()
                for stmt in tree.body:
                    if isinstance(stmt, ast.Assign) and isinstance(stmt.value, ast.Dict) and any(self._get_attr_name(t).endswith('beat_schedule') for t in stmt.targets):
                        for k, v in zip(stmt.value.keys, stmt.value.values):
                            if not isinstance(v, ast.Dict):
                                continue
                            entry = {kk.value: vv for kk, vv in zip(v.keys, v.values) if isinstance(kk, ast.Constant)}
                            task, sched = entry.get('task'), entry.get('schedule')
                            if sched is not None:
                                seen_time_nodes.update(id(n) for n in ast.walk(sched))
                            self.time_triggers.append({
                                'kind': 'beat', 'file': data['i'], 'symbol': None, 'how': 'beat_schedule',
                                'name': k.value if isinstance(k, ast.Constant) else None,
                                'task': task.value if isinstance(task, ast.Constant) else None,
                                'schedule': ast.unparse(sched) if sched is not None else None,
                                'ls': stmt.lineno})

                time_funcs = ('crontab', 'solar', 'schedule.every', 'repeat_every', 'scheduled_job', 'add_job', 'call_later', 'call_at', 'IntervalSchedule')

                def note_time_trigger(call_node, symbol_id=None):
                    """Clock-driven triggers (cron, scheduler jobs): TIME stickies on a process model."""
                    if id(call_node) in seen_time_nodes:
                        return
                    name = self._get_attr_name(call_node.func)
                    if not name.endswith(time_funcs):
                        return
                    spec = [repr(a.value) for a in call_node.args if isinstance(a, ast.Constant)]
                    spec += [f"{kw.arg}={kw.value.value!r}" for kw in call_node.keywords if isinstance(kw.value, ast.Constant)]
                    self.time_triggers.append({
                        'kind': 'cron' if name.endswith(('crontab', 'solar')) else 'scheduler',
                        'file': data['i'], 'symbol': symbol_id, 'how': name,
                        'schedule': ', '.join(spec), 'ls': getattr(call_node, 'lineno', 1)})

                def parse_route_decorator(dec):
                    func_obj = dec.func if isinstance(dec, ast.Call) else dec
                    name = self._get_attr_name(func_obj)
                    verb = None
                    router_var = self._get_attr_name(func_obj.value) if isinstance(func_obj, ast.Attribute) else None
                    if isinstance(func_obj, ast.Attribute) and func_obj.attr.lower() in route_verbs:
                        verb = func_obj.attr.upper()
                    path = None
                    if isinstance(dec, ast.Call) and dec.args:
                        arg0 = dec.args[0]
                        if isinstance(arg0, ast.Constant) and isinstance(arg0.value, str):
                            path = arg0.value
                    framework = None
                    lower_name = name.lower() if isinstance(name, str) else ''
                    if 'fastapi' in lower_name or 'router' in lower_name:
                        framework = 'fastapi'
                    elif 'flask' in lower_name:
                        framework = 'flask'
                    if verb:
                        return {'method': verb, 'path': path, 'framework': framework or 'unknown', 'router_var': router_var}
                    return None

                def guards_from_depends(call):
                    """Depends(has_permission([ROLE, ...])) -> roles; Depends(get_current_user) -> guard name.
                    Roles become the yellow person sticky; guards are refusals that exist before the handler runs."""
                    roles, guards = [], []
                    if not (isinstance(call, ast.Call) and self._get_attr_name(call.func).endswith('Depends') and call.args):
                        return roles, guards
                    inner = call.args[0]
                    inner_name = self._get_attr_name(inner.func if isinstance(inner, ast.Call) else inner)
                    lower = inner_name.lower()
                    if isinstance(inner, ast.Call) and any(k in lower for k in ('permission', 'role', 'require')):
                        for a in inner.args:
                            for el in (a.elts if isinstance(a, (ast.List, ast.Tuple, ast.Set)) else [a]):
                                if isinstance(el, ast.Attribute):
                                    roles.append(el.attr)
                                elif isinstance(el, ast.Constant):
                                    roles.append(str(el.value))
                        if not roles:
                            guards.append(inner_name)
                    elif any(k in lower for k in ('auth', 'user', 'permission', 'role', 'guard', 'token', 'login', 'session')):
                        guards.append(inner_name)
                    return roles, guards

                router_guards = {}
                for stmt in tree.body:
                    if isinstance(stmt, ast.Assign) and isinstance(stmt.value, ast.Call) and stmt.targets and isinstance(stmt.targets[0], ast.Name):
                        for kw in stmt.value.keywords:
                            if kw.arg == 'dependencies' and isinstance(kw.value, (ast.List, ast.Tuple)):
                                acc_roles, acc_guards = [], []
                                for el in kw.value.elts:
                                    r, g = guards_from_depends(el)
                                    acc_roles += r
                                    acc_guards += g
                                router_guards[stmt.targets[0].id] = (acc_roles, acc_guards)

                def describe_refusal(exc, line, when):
                    """`raise HTTPException(status_code=403, detail=...)`, `abort(404)`, `raise ValueError(...)`:
                    the alternative-outcome events a process model needs and docs never record."""
                    call = exc if isinstance(exc, ast.Call) else None
                    name = self._get_attr_name(call.func if call else exc)
                    args = list(call.args) if call else []
                    kws = {kw.arg: kw.value for kw in (call.keywords if call else []) if kw.arg}
                    status = msg = None
                    for v in [kws.get('status_code'), kws.get('status')] + args:
                        if isinstance(v, ast.Constant) and isinstance(v.value, int) and 100 <= v.value < 600:
                            status = v.value
                            break
                        if isinstance(v, ast.Attribute):
                            m = re.search(r'(?<!\d)([1-5]\d\d)(?!\d)', v.attr)
                            if m:
                                status = int(m.group(1))
                                break
                    for v in [kws.get(k) for k in ('detail', 'message', 'description', 'error', 'msg')] + args:
                        if isinstance(v, ast.Constant) and isinstance(v.value, str):
                            msg = v.value
                            break
                        if isinstance(v, (ast.JoinedStr, ast.Call)):
                            msg = ast.unparse(v)
                            break
                    out = {'ls': line, 'exc': name}
                    if status is not None:
                        out['status'] = status
                    if msg:
                        out['msg'] = msg[:160]
                    if when:
                        out['when'] = when[:160]
                    return out

                def collect_refusals(fn_node):
                    """Every raise / abort in a function body, with the nearest enclosing `if` test as `when`."""
                    found = []

                    def visit(node, when):
                        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef, ast.Lambda)):
                            return
                        if isinstance(node, ast.Raise):
                            # `raise` and `raise err` re-raise something caught; only a constructed exception is a refusal
                            if node.exc is not None and not (isinstance(node.exc, ast.Name) and node.exc.id[:1].islower()):
                                found.append(describe_refusal(node.exc, node.lineno, when))
                            return
                        if isinstance(node, ast.Call) and self._get_attr_name(node.func) in ('abort', 'flask.abort'):
                            found.append(describe_refusal(node, node.lineno, when))
                            return
                        if isinstance(node, ast.If):
                            test = ast.unparse(node.test)
                            for b in node.body:
                                visit(b, test)
                            for b in node.orelse:
                                visit(b, when if isinstance(b, ast.If) else f"not ({test})")
                            return
                        for child in ast.iter_child_nodes(node):
                            visit(child, when)

                    for stmt in fn_node.body:
                        visit(stmt, None)
                    return found

                def walk_module_level(node):
                    for child in ast.iter_child_nodes(node):
                        if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                            continue
                        yield child
                        for sub in walk_module_level(child):
                            yield sub

                # Module-level env usage
                for mod_node in walk_module_level(tree):
                    if isinstance(mod_node, ast.Call):
                        note_time_trigger(mod_node, None)
                        env_name = extract_env_from_call(mod_node)
                        if env_name:
                            record_env(env_name, mod_node, None)
                    if isinstance(mod_node, ast.Subscript):
                        env_name = extract_env_from_subscript(mod_node)
                        if env_name:
                            record_env(env_name, mod_node, None)

                for node in ast.walk(tree):
                    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                        symbol_id = get_symbol(node)
                        decorator_strs = [self._get_attr_name(dec) for dec in node.decorator_list]
                        # Task entry points (@celery_app.task, @shared_task, scheduler jobs): commands a policy issues
                        task_dec = next((d for d in decorator_strs if d == 'task' or d.endswith(('.task', 'shared_task', 'scheduled_job', 'repeat_every', 'periodic_task'))), None)
                        if task_dec and symbol_id in fn_by_id:
                            fn_by_id[symbol_id]['task'] = task_dec
                        is_route = any(any(dec.lower().endswith(verb) for verb in route_verbs) or '.route' in dec.lower() for dec in decorator_strs if isinstance(dec, str))
                        route_info = None
                        for dec in node.decorator_list:
                            if isinstance(dec, (ast.Call, ast.Attribute, ast.Name)):
                                parsed = parse_route_decorator(dec)
                                if parsed:
                                    route_info = parsed
                                    break
                        if route_info:
                            base_roles, base_guards = router_guards.get(route_info.get('router_var'), ([], []))
                            roles, guards = list(base_roles), list(base_guards)
                            a = node.args
                            positional_defaults = [None] * (len(a.args) - len(a.defaults)) + list(a.defaults)
                            for d in positional_defaults + list(a.kw_defaults):
                                if d is not None:
                                    r, g = guards_from_depends(d)
                                    roles += r
                                    guards += g
                            route_info['roles'] = sorted(set(roles))
                            route_info['guards'] = sorted(set(guards))
                        if is_route:
                            for dec in decorator_strs:
                                record_io('inputs', 'api', node, how=dec, where=None, symbol_id=symbol_id)
                            # Assume API handlers also emit API/JSON responses
                            record_io('outputs', 'api', node, how='return', where=None, symbol_id=symbol_id)
                        if route_info and symbol_id:
                            if symbol_id in fn_by_id:
                                fn_by_id[symbol_id]['route'] = route_info
                            self.routes.append({
                                'symbol': symbol_id,
                                'file': data['i'],
                                'method': route_info.get('method'),
                                'path': route_info.get('path'),
                                'framework': route_info.get('framework'),
                                'router_var': route_info.get('router_var'),
                                'roles': route_info.get('roles') or [],
                                'guards': route_info.get('guards') or []
                            })
                        if symbol_id in fn_by_id:
                            refusals = collect_refusals(node)
                            if refusals:
                                fn_by_id[symbol_id]['refusals'] = refusals
                        for sub in walk_function_body(node):
                            if isinstance(sub, ast.Call):
                                func_name = self._get_attr_name(sub.func)
                                # `self.session.add` has to match the `session.add` patterns below
                                func_name = re.sub(r'^(self|cls)\.', '', func_name)
                                lower_name = func_name.lower()
                                first_arg = sub.args[0] if sub.args else None

                                # Reactions: work handed to a background task, a queue, or the event loop.
                                # Each is a "whenever X then Y" policy candidate on a process model.
                                reaction_kind = None
                                if lower_name.endswith('.add_task'):
                                    reaction_kind = 'background'
                                elif lower_name.endswith(('.delay', '.apply_async', '.send_task', '.enqueue', '.enqueue_in', '.enqueue_at', '.publish')):
                                    reaction_kind = 'queue'
                                elif lower_name in ('asyncio.create_task', 'create_task', 'asyncio.ensure_future', 'loop.create_task'):
                                    reaction_kind = 'async'
                                if reaction_kind:
                                    if reaction_kind == 'queue':
                                        target = func_name.rsplit('.', 1)[0]
                                    else:
                                        target = self._get_attr_name(first_arg) if first_arg is not None else None
                                    record_io('outputs', 'reaction', sub, how=func_name, where=target, symbol_id=symbol_id)
                                    self.reactions.append({'symbol': symbol_id, 'file': data['i'], 'kind': reaction_kind, 'how': func_name, 'target': target, 'ls': getattr(sub, 'lineno', 1)})
                                note_time_trigger(sub, symbol_id)

                                # Database raw SQL (string-first) regardless of func name
                                sql_text = self._extract_sql_literal(first_arg) if first_arg is not None else None
                                sql_like = self._looks_like_sql(sql_text) if sql_text else False
                                if func_name in db_exec_funcs or sql_like:
                                    meta = self._parse_sql_metadata(sql_text) if sql_text else {}
                                    operation = meta.get('operation')
                                    schema = meta.get('schema')
                                    database = meta.get('database')
                                    tables_raw = meta.get('tables') or []
                                    if 'read_sql_table' in func_name and sql_text:
                                        tables_raw = tables_raw or [sql_text]
                                        operation = operation or 'SELECT'
                                    qualified_tables = [self._table_label(t, schema, database) for t in tables_raw]
                                    columns = meta.get('columns')
                                    direction = 'inputs'
                                    if operation and operation.upper() in ('INSERT', 'UPDATE', 'DELETE', 'CREATE', 'ALTER', 'DROP'):
                                        direction = 'outputs'
                                    where_hint = ', '.join(filter(None, qualified_tables)) if qualified_tables else None
                                    record_io(direction, 'database', sub, how=func_name, where=where_hint, symbol_id=symbol_id, tables=qualified_tables, operation=operation, columns=columns, sql_text=sql_text, schema=schema, database=database)
                                    continue

                                # HTTP client calls
                                if func_name in http_client_funcs or (lower_name.endswith('.fetch') or lower_name == 'fetch'):
                                    url_hint = first_arg.value if isinstance(first_arg, ast.Constant) and isinstance(first_arg.value, str) else None
                                    # Avoid classifying SQL fetchers as API
                                    if not (isinstance(url_hint, str) and self._looks_like_sql(url_hint)):
                                        record_io('inputs', 'api', sub, how=func_name, where=url_hint, symbol_id=symbol_id)
                                env_name = extract_env_from_call(sub)
                                if env_name:
                                    record_env(env_name, sub, symbol_id)

                                # CSV input/output
                                if func_name in csv_read_funcs:
                                    path_hint = first_arg.value if isinstance(first_arg, ast.Constant) and isinstance(first_arg.value, str) else None
                                    record_io('inputs', 'csv', sub, how=func_name, where=path_hint, symbol_id=symbol_id)
                                if func_name in csv_write_funcs:
                                    record_io('outputs', 'csv', sub, how=func_name, where=None, symbol_id=symbol_id)
                                if func_name == 'open' and isinstance(first_arg, ast.Constant) and isinstance(first_arg.value, str) and first_arg.value.endswith('.csv'):
                                    mode = 'r'
                                    if len(sub.args) > 1 and isinstance(sub.args[1], ast.Constant) and isinstance(sub.args[1].value, str):
                                        mode = sub.args[1].value
                                    direction = 'outputs' if 'w' in mode or 'a' in mode else 'inputs'
                                    record_io(direction, 'csv', sub, how='open', where=first_arg.value, symbol_id=symbol_id)

                                # JSON input/output
                                if func_name in json_in_funcs:
                                    record_io('inputs', 'json', sub, how=func_name, where=None, symbol_id=symbol_id)
                                if func_name in json_out_funcs:
                                    record_io('outputs', 'json', sub, how=func_name, where=None, symbol_id=symbol_id)
                                if isinstance(sub.func, ast.Attribute) and sub.func.attr == 'json':
                                    record_io('inputs', 'json', sub, how='response.json', where=None, symbol_id=symbol_id)
                                if func_name == 'open' and isinstance(first_arg, ast.Constant) and isinstance(first_arg.value, str) and first_arg.value.endswith('.json'):
                                    mode = 'r'
                                    if len(sub.args) > 1 and isinstance(sub.args[1], ast.Constant) and isinstance(sub.args[1].value, str):
                                        mode = sub.args[1].value
                                    direction = 'outputs' if 'w' in mode or 'a' in mode else 'inputs'
                                    record_io(direction, 'json', sub, how='open', where=first_arg.value, symbol_id=symbol_id)

                                # DataFrame input/output
                                if func_name and any(func_name.endswith(df) for df in df_in_funcs):
                                    record_io('inputs', 'dataframe', sub, how=func_name, where=None, symbol_id=symbol_id)
                                if isinstance(sub.func, ast.Attribute) and sub.func.attr in df_out_attrs:
                                    how = f"DataFrame.{sub.func.attr}"
                                    dest_kind = {'to_sql': 'database', 'to_csv': 'csv', 'to_json': 'json', 'to_parquet': 'dataframe'}.get(sub.func.attr, 'dataframe')
                                    table_hint = None
                                    tables = None
                                    operation = None
                                    schema = None
                                    if dest_kind == 'database' and sub.args:
                                        if isinstance(sub.args[0], ast.Constant) and isinstance(sub.args[0].value, str):
                                            table_hint = sub.args[0].value
                                            tables = [self._qualify_table(table_hint)]
                                            operation = 'INSERT'
                                    record_io('outputs', dest_kind if dest_kind else 'dataframe', sub, how=how, where=table_hint, symbol_id=symbol_id, tables=tables, operation=operation)

                                # ORM reads
                                if func_name in orm_read_funcs:
                                    tables = []
                                    schema_hint = None
                                    for arg in sub.args:
                                        model_key = None
                                        if isinstance(arg, ast.Name):
                                            model_key = arg.id
                                        elif isinstance(arg, ast.Attribute):
                                            model_key = arg.attr
                                        if model_key and model_key in self.orm_models:
                                            model_info = self.orm_models[model_key]
                                            schema_hint = schema_hint or model_info.get('schema')
                                            tables.append(self._table_label(model_info['table_name'], model_info.get('schema')))
                                    if tables:
                                        where_hint = ', '.join(tables)
                                        record_io('inputs', 'database', sub, how=func_name, where=where_hint, symbol_id=symbol_id, tables=tables, operation='ORM', schema=schema_hint)

                                # ORM writes
                                if func_name in orm_write_funcs:
                                    tables = []
                                    schema_hint = None
                                    for arg in sub.args:
                                        model_key = None
                                        if isinstance(arg, ast.Name):
                                            model_key = arg.id
                                        elif isinstance(arg, ast.Attribute):
                                            model_key = arg.attr
                                        if model_key and model_key in self.orm_models:
                                            model_info = self.orm_models[model_key]
                                            schema_hint = schema_hint or model_info.get('schema')
                                            tables.append(self._table_label(model_info['table_name'], model_info.get('schema')))
                                    where_hint = ', '.join(tables) if tables else None
                                    record_io('outputs', 'database', sub, how=func_name, where=where_hint, symbol_id=symbol_id, tables=tables or None, operation='ORM', schema=schema_hint)

                            if isinstance(sub, ast.Return):
                                if isinstance(sub.value, ast.Dict):
                                    record_io('outputs', 'json', sub, how='return', where=None, symbol_id=symbol_id)
                                if isinstance(sub.value, ast.List):
                                    record_io('outputs', 'list', sub, how='return', where=None, symbol_id=symbol_id)
                            if isinstance(sub, ast.Subscript):
                                env_name = extract_env_from_subscript(sub)
                                if env_name:
                                    record_env(env_name, sub, symbol_id)
                for stmt in tree.body:
                    if isinstance(stmt, ast.Assign) and isinstance(stmt.value, ast.Call):
                        ctor = self._get_attr_name(stmt.value.func)
                        if ctor and any(key in ctor.lower() for key in ['config', 'client', 'connector', 'engine', 'session', 'singleton', 'redis', 'db']):
                            target_name = None
                            if stmt.targets and isinstance(stmt.targets[0], ast.Name):
                                target_name = stmt.targets[0].id
                            record_io('inputs', 'singleton', stmt, how=ctor, where=target_name, symbol_id=None)
                            record_io('outputs', 'singleton', stmt, how=ctor, where=target_name, symbol_id=None)
                self.data_io[file_path] = io_record
                data['data_io'] = io_record
                data['env_usage'] = file_env_usage

            else:
                # Enhanced JS/TS heuristic scanning
                try:
                    with open(file_path, 'r', encoding='utf-8') as f:
                        content = f.read()
                except Exception:
                    content = ''

                file_env_usage = []

                def make_dummy(line_no):
                    return type('obj', (), {'lineno': line_no, 'end_lineno': line_no})()

                # Build function map for symbol association
                fn_map = {fn['ls']: fn['i'] for fn in data.get('fns', [])}

                def get_nearest_symbol(line_no):
                    """Find the function containing this line"""
                    for fn in data.get('fns', []):
                        if fn.get('ls', 0) <= line_no <= fn.get('le', 0):
                            return fn.get('i')
                    return None

                # === HTTP Client Patterns ===
                # fetch(), axios, got, node-fetch, ky, request, superagent
                http_patterns = [
                    (r'\bfetch\s*\(\s*[\'"`]([^\'"` ]+)[\'"`]', 'fetch'),
                    (r'\baxios\.(get|post|put|patch|delete|request)\s*\(\s*[\'"`]?([^\'"`,\s)]+)?', 'axios'),
                    (r'\bgot\.(get|post|put|patch|delete)\s*\(\s*[\'"`]?([^\'"`,\s)]+)?', 'got'),
                    (r'\brequest\.(get|post|put|patch|delete)\s*\(\s*[\'"`]?([^\'"`,\s)]+)?', 'request'),
                    (r'\bky\.(get|post|put|patch|delete)\s*\(\s*[\'"`]?([^\'"`,\s)]+)?', 'ky'),
                    (r'\bsuperagent\.(get|post|put|patch|delete)\s*\(\s*[\'"`]?([^\'"`,\s)]+)?', 'superagent'),
                ]
                for pattern, lib in http_patterns:
                    for match in re.finditer(pattern, content, re.I):
                        line_no = content[:match.start()].count('\n') + 1
                        url_hint = match.group(2) if len(match.groups()) > 1 and match.group(2) else match.group(1) if match.group(1) else None
                        how = f"{lib}.{match.group(1)}" if len(match.groups()) > 1 else lib
                        symbol_id = get_nearest_symbol(line_no)
                        record_io('inputs', 'api', make_dummy(line_no), how=how, where=url_hint, symbol_id=symbol_id)

                # === Express/Fastify/Koa Route Patterns ===
                route_patterns = [
                    (r'(?:app|router)\.(get|post|put|patch|delete|all)\s*\(\s*[\'"`]([^\'"` ]+)[\'"`]', 'express'),
                    (r'fastify\.(get|post|put|patch|delete)\s*\(\s*[\'"`]([^\'"` ]+)[\'"`]', 'fastify'),
                ]
                for pattern, framework in route_patterns:
                    for match in re.finditer(pattern, content, re.I):
                        line_no = content[:match.start()].count('\n') + 1
                        method = match.group(1).upper()
                        path = match.group(2)
                        symbol_id = get_nearest_symbol(line_no)
                        record_io('inputs', 'api', make_dummy(line_no), how=f"{framework}.{method}", where=path, symbol_id=symbol_id)
                        record_io('outputs', 'api', make_dummy(line_no), how='response', where=path, symbol_id=symbol_id)
                        # Middleware between the path and the handler: auth / role guards and the roles they name
                        guards, roles = [], []
                        mw = re.match(r'\s*,\s*([A-Za-z_$][\w$.]*)\s*(?:\(([^)]*)\))?\s*,', content[match.end():match.end() + 300])
                        if mw and re.search(r'auth|role|permission|guard|protect|require|verify|session', mw.group(1), re.I):
                            guards.append(mw.group(1))
                            roles = re.findall(r'[\'"`]([^\'"`]+)[\'"`]', mw.group(2) or '')
                        # Inline arrow handlers have no symbol of their own; the route is still a command
                        self.routes.append({
                            'symbol': symbol_id,
                            'file': data['i'],
                            'method': method,
                            'path': path,
                            'framework': framework,
                            'roles': sorted(set(roles)),
                            'guards': guards,
                            'ls': line_no
                        })

                # === Refusals: throw / 4xx-5xx responses, attributed to the enclosing named function ===
                js_fn_by_id = {fn['i']: fn for fn in data.get('fns', [])}
                js_refusal_patterns = [
                    (r'\bthrow\s+new\s+([A-Za-z_$][\w$.]*)\s*\(\s*(?:[\'"`]([^\'"`\n]{0,160})[\'"`])?', 'throw'),
                    (r'\.(?:status|code|sendStatus)\s*\(\s*([45]\d\d)\s*\)', 'status'),
                ]
                for pattern, kind in js_refusal_patterns:
                    for match in re.finditer(pattern, content):
                        line_no = content[:match.start()].count('\n') + 1
                        fn = js_fn_by_id.get(get_nearest_symbol(line_no))
                        if fn is None:
                            continue
                        entry = {'ls': line_no}
                        if kind == 'throw':
                            entry['exc'] = match.group(1)
                            if match.group(2):
                                entry['msg'] = match.group(2)
                        else:
                            entry['exc'] = 'response'
                            entry['status'] = int(match.group(1))
                        fn.setdefault('refusals', []).append(entry)

                # === Queues, schedulers, timers (policy and time-trigger candidates) ===
                js_reaction_patterns = [
                    (r'\b(\w*[Qq]ueue\w*)\.add\s*\(', 'queue'),                          # bull / bullmq
                    (r'\b(\w+)\.(?:enqueue|publish|sendMessage)\s*\(', 'queue'),         # SQS, pub/sub, generic
                    (r'\binngest\.send\s*\(', 'queue'),
                    (r'\b(?:ctx\.)?scheduler\.(?:runAfter|runAt)\s*\(', 'queue'),        # convex
                    (r'\bwaitUntil\s*\(', 'background'),                                 # vercel / cloudflare
                ]
                for pattern, kind in js_reaction_patterns:
                    for match in re.finditer(pattern, content):
                        line_no = content[:match.start()].count('\n') + 1
                        symbol_id = get_nearest_symbol(line_no)
                        how = match.group(0).rstrip('( ').strip()
                        record_io('outputs', 'reaction', make_dummy(line_no), how=how, where=None, symbol_id=symbol_id)
                        self.reactions.append({'symbol': symbol_id, 'file': data['i'], 'kind': kind, 'how': how, 'target': None, 'ls': line_no})
                js_time_patterns = [
                    (r'\bcron\.schedule\s*\(\s*[\'"`]([^\'"`]+)[\'"`]', 'cron'),          # node-cron
                    (r'new\s+CronJob\s*\(\s*[\'"`]([^\'"`]+)[\'"`]', 'cron'),              # cron
                    (r'\bschedule\.scheduleJob\s*\(\s*[\'"`]([^\'"`]+)[\'"`]', 'cron'),    # node-schedule
                    (r'\bcrons\.(?:interval|cron|daily|hourly|weekly|monthly)\s*\(', 'cron'),  # convex
                    (r'\bsetInterval\s*\(', 'interval'),
                ]
                for pattern, kind in js_time_patterns:
                    for match in re.finditer(pattern, content):
                        line_no = content[:match.start()].count('\n') + 1
                        symbol_id = get_nearest_symbol(line_no)
                        self.time_triggers.append({'kind': kind, 'file': data['i'], 'symbol': symbol_id,
                                                   'how': match.group(0).split('(')[0].strip(),
                                                   'schedule': match.group(1) if match.lastindex else None, 'ls': line_no})

                # === Prisma ORM ===
                prisma_patterns = [
                    (r'prisma\.(\w+)\.(findMany|findFirst|findUnique|findUniqueOrThrow|count|aggregate|groupBy)', 'inputs', 'ORM'),
                    (r'prisma\.(\w+)\.(create|createMany|update|updateMany|upsert|delete|deleteMany)', 'outputs', 'ORM'),
                ]
                for pattern, direction, operation in prisma_patterns:
                    for match in re.finditer(pattern, content):
                        line_no = content[:match.start()].count('\n') + 1
                        model = match.group(1)
                        method = match.group(2)
                        symbol_id = get_nearest_symbol(line_no)
                        record_io(direction, 'database', make_dummy(line_no), how=f"prisma.{method}", where=model, symbol_id=symbol_id, tables=[model], operation=operation)

                # === TypeORM ===
                typeorm_patterns = [
                    (r'(?:repository|manager)\.(find|findOne|findBy|findOneBy|count|query)\s*\(', 'inputs', 'ORM'),
                    (r'(?:repository|manager)\.(save|insert|update|delete|remove|softDelete)\s*\(', 'outputs', 'ORM'),
                    (r'getRepository\s*\(\s*(\w+)\s*\)', 'inputs', 'ORM'),
                    (r'createQueryBuilder\s*\(\s*[\'"`]?(\w+)?[\'"`]?\s*\)', 'inputs', 'ORM'),
                ]
                for pattern, direction, operation in typeorm_patterns:
                    for match in re.finditer(pattern, content):
                        line_no = content[:match.start()].count('\n') + 1
                        table = match.group(1) if match.lastindex >= 1 else None
                        symbol_id = get_nearest_symbol(line_no)
                        record_io(direction, 'database', make_dummy(line_no), how='typeorm', where=table, symbol_id=symbol_id, tables=[table] if table else None, operation=operation)

                # === Sequelize ===
                sequelize_patterns = [
                    (r'(\w+)\.(findAll|findOne|findByPk|findAndCountAll|count)\s*\(', 'inputs', 'ORM'),
                    (r'(\w+)\.(create|bulkCreate|update|destroy|upsert)\s*\(', 'outputs', 'ORM'),
                ]
                for pattern, direction, operation in sequelize_patterns:
                    for match in re.finditer(pattern, content):
                        line_no = content[:match.start()].count('\n') + 1
                        model = match.group(1)
                        method = match.group(2)
                        # Skip if it's clearly not a Sequelize model (common JS methods)
                        if model.lower() in {'array', 'object', 'promise', 'json', 'console', 'math', 'string', 'number', 'date', 'map', 'set'}:
                            continue
                        symbol_id = get_nearest_symbol(line_no)
                        record_io(direction, 'database', make_dummy(line_no), how=f"sequelize.{method}", where=model, symbol_id=symbol_id, tables=[model], operation=operation)

                # === Drizzle ===
                drizzle_patterns = [
                    (r'db\.select\s*\(\s*\)\.from\s*\(\s*(\w+)\s*\)', 'inputs', 'SELECT'),
                    (r'db\.insert\s*\(\s*(\w+)\s*\)', 'outputs', 'INSERT'),
                    (r'db\.update\s*\(\s*(\w+)\s*\)', 'outputs', 'UPDATE'),
                    (r'db\.delete\s*\(\s*(\w+)\s*\)', 'outputs', 'DELETE'),
                ]
                for pattern, direction, operation in drizzle_patterns:
                    for match in re.finditer(pattern, content):
                        line_no = content[:match.start()].count('\n') + 1
                        table = match.group(1)
                        symbol_id = get_nearest_symbol(line_no)
                        record_io(direction, 'database', make_dummy(line_no), how=f"drizzle.{operation.lower()}", where=table, symbol_id=symbol_id, tables=[table], operation=operation)

                # === Knex/Raw SQL ===
                sql_patterns = [
                    (r'knex\s*\(\s*[\'"`](\w+)[\'"`]\s*\)', 'inputs', 'SELECT'),
                    (r'\.raw\s*\(\s*[\'"`](select[^\'"`]+)[\'"`]', 'inputs', 'SELECT'),
                    (r'\.raw\s*\(\s*[\'"`](insert[^\'"`]+)[\'"`]', 'outputs', 'INSERT'),
                    (r'\.raw\s*\(\s*[\'"`](update[^\'"`]+)[\'"`]', 'outputs', 'UPDATE'),
                    (r'\.raw\s*\(\s*[\'"`](delete[^\'"`]+)[\'"`]', 'outputs', 'DELETE'),
                    (r'query\s*\(\s*[\'"`](select[^\'"`]+)[\'"`]', 'inputs', 'SELECT'),
                    (r'query\s*\(\s*[\'"`](insert[^\'"`]+)[\'"`]', 'outputs', 'INSERT'),
                    (r'execute\s*\(\s*[\'"`](select[^\'"`]+)[\'"`]', 'inputs', 'SELECT'),
                ]
                for pattern, direction, operation in sql_patterns:
                    for match in re.finditer(pattern, content, re.I):
                        line_no = content[:match.start()].count('\n') + 1
                        sql_snippet = match.group(1)
                        symbol_id = get_nearest_symbol(line_no)
                        # Try to extract table name from SQL
                        table_match = re.search(r'(?:from|into|update)\s+[`"\[]?(\w+)[`"\]]?', sql_snippet, re.I)
                        table = table_match.group(1) if table_match else None
                        record_io(direction, 'database', make_dummy(line_no), how='sql', where=table, symbol_id=symbol_id, tables=[table] if table else None, operation=operation, sql_text=sql_snippet[:100])

                # === MongoDB ===
                mongo_patterns = [
                    (r'(?:collection|db)\.(\w+)\.(find|findOne|aggregate|countDocuments)\s*\(', 'inputs'),
                    (r'(?:collection|db)\.(\w+)\.(insertOne|insertMany|updateOne|updateMany|deleteOne|deleteMany|replaceOne)\s*\(', 'outputs'),
                ]
                for pattern, direction in mongo_patterns:
                    for match in re.finditer(pattern, content):
                        line_no = content[:match.start()].count('\n') + 1
                        collection = match.group(1)
                        method = match.group(2)
                        symbol_id = get_nearest_symbol(line_no)
                        record_io(direction, 'database', make_dummy(line_no), how=f"mongodb.{method}", where=collection, symbol_id=symbol_id, tables=[collection], operation='MONGODB')

                # === Redis ===
                redis_patterns = [
                    (r'redis\.(get|hget|hgetall|lrange|smembers|zrange|mget)\s*\(', 'inputs'),
                    (r'redis\.(set|hset|lpush|rpush|sadd|zadd|mset|setex|del)\s*\(', 'outputs'),
                ]
                for pattern, direction in redis_patterns:
                    for match in re.finditer(pattern, content, re.I):
                        line_no = content[:match.start()].count('\n') + 1
                        method = match.group(1)
                        symbol_id = get_nearest_symbol(line_no)
                        record_io(direction, 'cache', make_dummy(line_no), how=f"redis.{method}", where=None, symbol_id=symbol_id)

                # === File System ===
                fs_read_patterns = [
                    r'fs\.(?:readFile|readFileSync|createReadStream)\s*\(\s*[\'"`]?([^\'"`,\s)]+)?',
                    r'readFile\s*\(\s*[\'"`]([^\'"` ]+)[\'"`]',
                ]
                fs_write_patterns = [
                    r'fs\.(?:writeFile|writeFileSync|createWriteStream|appendFile|appendFileSync)\s*\(\s*[\'"`]?([^\'"`,\s)]+)?',
                    r'writeFile\s*\(\s*[\'"`]([^\'"` ]+)[\'"`]',
                ]
                for pattern in fs_read_patterns:
                    for match in re.finditer(pattern, content):
                        line_no = content[:match.start()].count('\n') + 1
                        path_hint = match.group(1) if match.lastindex >= 1 else None
                        symbol_id = get_nearest_symbol(line_no)
                        record_io('inputs', 'file', make_dummy(line_no), how='fs.read', where=path_hint, symbol_id=symbol_id)
                for pattern in fs_write_patterns:
                    for match in re.finditer(pattern, content):
                        line_no = content[:match.start()].count('\n') + 1
                        path_hint = match.group(1) if match.lastindex >= 1 else None
                        symbol_id = get_nearest_symbol(line_no)
                        record_io('outputs', 'file', make_dummy(line_no), how='fs.write', where=path_hint, symbol_id=symbol_id)

                # === WebSocket ===
                ws_patterns = [
                    r'(?:new\s+)?WebSocket\s*\(\s*[\'"`]([^\'"` ]+)[\'"`]',
                    r'(?:io|socket)\.(?:on|emit)\s*\(\s*[\'"`](\w+)[\'"`]',
                ]
                for pattern in ws_patterns:
                    for match in re.finditer(pattern, content):
                        line_no = content[:match.start()].count('\n') + 1
                        target = match.group(1)
                        symbol_id = get_nearest_symbol(line_no)
                        record_io('inputs', 'websocket', make_dummy(line_no), how='websocket', where=target, symbol_id=symbol_id)
                        record_io('outputs', 'websocket', make_dummy(line_no), how='websocket', where=target, symbol_id=symbol_id)

                # === Environment Variables ===
                env_pattern = r'process\.env\.(\w+)|process\.env\[[\'"`](\w+)[\'"`]\]'
                for match in re.finditer(env_pattern, content):
                    line_no = content[:match.start()].count('\n') + 1
                    env_name = match.group(1) or match.group(2)
                    symbol_id = get_nearest_symbol(line_no)
                    file_env_usage.append({
                        'name': env_name,
                        'ls': line_no,
                        'le': line_no
                    })
                    self.env_index[env_name]['files'].add(data['i'])
                    if symbol_id:
                        self.env_index[env_name]['symbols'].add(symbol_id)

                # === JSON Parsing ===
                json_patterns = [
                    (r'JSON\.parse\s*\(', 'inputs', 'json'),
                    (r'JSON\.stringify\s*\(', 'outputs', 'json'),
                ]
                for pattern, direction, kind in json_patterns:
                    for match in re.finditer(pattern, content):
                        line_no = content[:match.start()].count('\n') + 1
                        symbol_id = get_nearest_symbol(line_no)
                        record_io(direction, kind, make_dummy(line_no), how='JSON', where=None, symbol_id=symbol_id)

                self.data_io[file_path] = io_record
                data['data_io'] = io_record
                data['env_usage'] = file_env_usage

        # Attach IO summaries back to symbols
        for file_path, data in self.analysis.items():
            for fn in data.get('fns', []):
                sym_io = self.symbol_io.get(fn['i'])
                if not sym_io:
                    continue
                if sym_io['io_in']:
                    fn['io_in'] = sorted(sym_io['io_in'])
                if sym_io['io_out']:
                    fn['io_out'] = sorted(sym_io['io_out'])
                if sym_io['inputs'] or sym_io['outputs']:
                    fn['io_detail'] = {
                        'inputs': sym_io['inputs'],
                        'outputs': sym_io['outputs']
                    }
                if sym_io['db_in']:
                    fn['db_tables_in'] = sorted(sym_io['db_in'])
                if sym_io['db_out']:
                    fn['db_tables_out'] = sorted(sym_io['db_out'])

    
    def _find_module_file(self, module, level, from_file):
        """Map a dotted module from an import statement to an analysed file, or None."""
        from_path = Path(from_file)
        rel = (module or '').replace('.', os.sep)
        if level:
            base = from_path.parent
            for _ in range(level - 1):
                base = base.parent
            candidates = [base / f"{rel}.py", base / rel / '__init__.py'] if rel else [base / '__init__.py']
        else:
            hit = self.module_lookup.get(module)
            if hit and str(hit) in self.analysis:
                return str(hit)
            candidates = []
            for anc in [from_path.parent] + list(from_path.parents):
                candidates += [anc / f"{rel}.py", anc / rel / '__init__.py']
                if anc == self.root_dir:
                    break
        return next((str(c) for c in candidates if str(c) in self.analysis), None)

    def resolve_route_prefixes(self):
        """Join mount prefixes (FastAPI include_router, Flask register_blueprint) onto each route so
        `full_path` is what a client actually calls, not just the fragment on the decorator."""
        router_prefix, parent_of = {}, {}
        file_by_id = {d['i']: fp for fp, d in self.analysis.items()}

        def const_kw(call, keys):
            for kw in call.keywords:
                if kw.arg in keys and isinstance(kw.value, ast.Constant) and isinstance(kw.value.value, str):
                    return kw.value.value
            return ''

        for file_path, data in self.analysis.items():
            if not file_path.endswith('.py'):
                continue
            try:
                with open(file_path, 'r', encoding='utf-8') as f:
                    tree = ast.parse(f.read())
            except Exception:
                continue
            aliases = {}
            for node in ast.walk(tree):
                if isinstance(node, ast.ImportFrom):
                    for a in node.names:
                        aliases[a.asname or a.name] = (node.module, node.level, a.name)
            for stmt in tree.body:
                if isinstance(stmt, ast.Assign) and isinstance(stmt.value, ast.Call) and stmt.targets and isinstance(stmt.targets[0], ast.Name):
                    if self._get_attr_name(stmt.value.func).endswith(('APIRouter', 'Blueprint', 'FastAPI', 'Flask')):
                        router_prefix[(file_path, stmt.targets[0].id)] = const_kw(stmt.value, ('prefix', 'url_prefix'))
            for node in ast.walk(tree):
                if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                        and node.func.attr in ('include_router', 'register_blueprint') and node.args):
                    continue
                parent_key = (file_path, self._get_attr_name(node.func.value))
                child = node.args[0]
                if isinstance(child, ast.Name):
                    module, level, orig = aliases.get(child.id, (None, 0, child.id))
                    child_file = self._find_module_file(module, level, file_path) if (module or level) else file_path
                    child_var = orig
                elif isinstance(child, ast.Attribute) and isinstance(child.value, ast.Name):
                    module, level, orig = aliases.get(child.value.id, (child.value.id, 0, None))
                    child_file = self._find_module_file(f"{module}.{orig}" if orig else module, level, file_path)
                    child_var = child.attr
                else:
                    continue
                if child_file:
                    parent_of[(child_file, child_var)] = (parent_key, const_kw(node, ('prefix', 'url_prefix')))

        def full_prefix(key, depth=0):
            own = router_prefix.get(key, '')
            if key in parent_of and depth < 8:
                parent_key, mount = parent_of[key]
                return full_prefix(parent_key, depth + 1) + mount + own
            return own

        fn_by_symbol = {fn['i']: fn for d in self.analysis.values() for fn in d.get('fns', [])}
        for r in self.routes:
            fp, var = file_by_id.get(r.get('file')), r.get('router_var')
            if fp and var and r.get('path') is not None:
                r['full_path'] = full_prefix((fp, var)) + r['path']
                fn = fn_by_symbol.get(r.get('symbol'))
                if fn and isinstance(fn.get('route'), dict):
                    fn['route']['full_path'] = r['full_path']

    def aggregate_refusals(self):
        """Walk each route's call graph (depth 3) and gather every raise / abort on the way: the ways
        the command can be refused. Handler first, callees after; `fn` and `file` say where."""
        fn_by_symbol = {fn['i']: fn for d in self.analysis.values() for fn in d.get('fns', [])}
        fn_file = {fn['i']: d.get('lc') for d in self.analysis.values() for fn in d.get('fns', [])}
        for r in self.routes:
            seen, frontier, found = set(), [(r.get('symbol'), 0)], []
            while frontier:
                sid, depth = frontier.pop(0)
                if sid in seen or sid not in fn_by_symbol or depth > 3:
                    continue
                seen.add(sid)
                fn = fn_by_symbol[sid]
                found += [dict(ref, fn=fn.get('n'), file=fn_file.get(sid)) for ref in fn.get('refusals') or []]
                frontier += [(c, depth + 1) for c in fn.get('sym_calls') or []]
            if found:
                r['refusals'] = found
        # A refusal reachable from most routes (an error helper, a shared auth check) says nothing about
        # any one command: list it once at the top level instead of on every route.
        reach = {}
        for r in self.routes:
            for ref in r.get('refusals') or []:
                reach.setdefault((ref.get('file'), ref['ls']), set()).add(id(r))
        routed = sum(1 for r in self.routes if r.get('refusals'))
        shared = {k for k, v in reach.items() if routed >= 4 and len(v) > routed / 2}
        self.shared_refusals = []
        for r in self.routes:
            if not r.get('refusals'):
                continue
            for ref in r['refusals']:
                if (ref.get('file'), ref['ls']) in shared and ref not in self.shared_refusals:
                    self.shared_refusals.append(ref)
            r['refusals'] = [ref for ref in r['refusals'] if (ref.get('file'), ref['ls']) not in shared] or None
            if r['refusals'] is None:
                del r['refusals']

    def find_absences(self):
        """Declared but never used. Leads for hotspots, not findings: `models_never_constructed` is
        noisy behind a generic repository (`self.model(**data)` constructs nothing by name)."""
        defined = {fn['n'] for d in self.analysis.values() for fn in d.get('fns', [])}
        refs, built = set(), set()
        for d in self.analysis.values():
            refs |= set(d.pop('_name_refs', ()))
            built |= set(d.pop('_constructed', ()))
        models = {n: i for n, i in self.orm_models.items() if isinstance(n, str) and n[:1].isupper() and i.get('table_name')}

        def entry(n, i):
            return {'model': n, 'table': i['table_name'], 'file': os.path.relpath(i['file'], str(self.root_dir)) if i.get('file') else None}

        return {
            'scheduled_tasks_undefined': [
                {'name': t.get('name'), 'task': t['task'], 'file': t['file'], 'ls': t['ls']}
                for t in self.time_triggers
                if t.get('kind') == 'beat' and t.get('task') and t['task'].rsplit('.', 1)[-1] not in defined],
            'models_unreferenced': [entry(n, i) for n, i in sorted(models.items()) if n not in refs],
            'models_never_constructed': [entry(n, i) for n, i in sorted(models.items()) if n not in built],
        }

    def resolve_import(self, import_str, from_file):
        """Attempt to resolve import to actual file path"""
        if not import_str:
            return None

        import_str = import_str.strip()
        if not import_str:
            return None

        # Detect JS/TS path-style imports (contain / after optional ./ or ../)
        is_path_style = '/' in import_str or (import_str.startswith('.') and not import_str.startswith('..') and len(import_str) > 1 and import_str[1] != '.')

        if import_str.startswith('.'):
            base_dir = from_file.parent

            # JS/TS path-style: ./foo/bar or ../foo/bar
            if is_path_style or '/' in import_str:
                # Normalize the path
                path_part = import_str

                # Handle ../ prefix navigation
                while path_part.startswith('../'):
                    base_dir = base_dir.parent
                    path_part = path_part[3:]

                # Handle ./ prefix
                if path_part.startswith('./'):
                    path_part = path_part[2:]
                elif path_part.startswith('.'):
                    path_part = path_part[1:].lstrip('/')

                if not path_part:
                    return None

                # Build candidate path
                candidate_path = base_dir / path_part

                # If path already has a recognized extension, try it directly
                if candidate_path.suffix in SUPPORTED_EXTENSIONS:
                    if candidate_path.exists():
                        return candidate_path
                    # Also try without the extension (in case it was added incorrectly)
                    base_without_ext = candidate_path.with_suffix('')
                    for ext in SUPPORTED_EXTENSIONS:
                        alt = base_without_ext.with_suffix(ext)
                        if alt.exists():
                            return alt

                # Try as-is first (might be extensionless in import)
                if candidate_path.exists() and candidate_path.is_file():
                    return candidate_path

                # Try adding extensions
                for ext in SUPPORTED_EXTENSIONS:
                    with_ext = candidate_path.with_suffix(ext)
                    if with_ext.exists():
                        return with_ext

                # Try as directory with index files
                if candidate_path.is_dir():
                    for index_name in ['index.js', 'index.ts', 'index.tsx', 'index.jsx', 'index.mjs', '__init__.py']:
                        index_file = candidate_path / index_name
                        if index_file.exists():
                            return index_file

                return None

            # Python-style relative import: .module or ..module
            parts = import_str.split('.')
            for part in parts:
                if part == '':
                    base_dir = base_dir.parent

            target = parts[-1]
            for ext in SUPPORTED_EXTENSIONS:
                candidate = base_dir / f"{target}{ext}"
                if candidate.exists():
                    return candidate
            return None

        # Relative traversal: try to resolve to sibling modules
        rel_candidate = from_file.parent / import_str.replace('.', '/')
        if rel_candidate.is_dir():
            for name in ['__init__.py', 'index.js', 'index.ts', 'index.tsx', 'index.jsx']:
                candidate = rel_candidate / name
                if candidate.exists():
                    return candidate
        for ext in SUPPORTED_EXTENSIONS:
            candidate = rel_candidate.with_suffix(ext)
            if candidate.exists():
                return candidate
        
        # Try module lookup regardless of traversal mode
        lookup_key = import_str.replace('/', '.')
        while lookup_key:
            if lookup_key in self.module_lookup:
                return self.module_lookup[lookup_key]
            if '.' not in lookup_key:
                break
            lookup_key = lookup_key.rsplit('.', 1)[0]

        if self.traversal_mode != 'absolute':
            return None
        
        normalized = import_str.replace('.', '/').strip('/')
        if not normalized:
            return None
        
        base_path = self.root_dir / normalized
        candidates = []
        
        if base_path.suffix:
            candidates.append(base_path)
        else:
            for ext in SUPPORTED_EXTENSIONS:
                candidates.append(base_path.with_suffix(ext))
        
        for candidate in candidates:
            if candidate.exists():
                return candidate
        
        if base_path.is_dir():
            fallback_files = ['__init__.py', 'index.js', 'index.ts', 'index.tsx', 'index.jsx']
            for name in fallback_files:
                candidate = base_path / name
                if candidate.exists():
                    return candidate
        
        lookup_key = import_str.replace('/', '.')
        while lookup_key:
            if lookup_key in self.module_lookup:
                return self.module_lookup[lookup_key]
            if '.' not in lookup_key:
                break
            lookup_key = lookup_key.rsplit('.', 1)[0]
        
        return None
    
    def generate_summary(self):
        """Generate summary statistics"""
        total_functions = sum(len(data.get('fns', [])) for data in self.analysis.values())
        total_classes = sum(len(data.get('cls', [])) for data in self.analysis.values())
        total_files = len(self.analysis)
        total_loc = sum(data.get('loc', 0) for data in self.analysis.values())
        duplicate_count = len(getattr(self, 'duplicate_filenames', {}))
        gitignored_included = sum(1 for data in self.analysis.values() if data.get('gi'))
        
        # NEW: Marker statistics
        marker_stats = defaultdict(int)
        for marker in self.markers:
            marker_stats[marker['k']] += 1
        
        risk_count = sum(1 for data in self.analysis.values() if 'r' in data)
        if risk_count > total_files * 0.3:
            risk_level = 'high'
        elif risk_count > total_files * 0.1:
            risk_level = 'medium'
        else:
            risk_level = 'low'
        
        return {
            'total_files': total_files,
            'total_functions': total_functions,
            'total_classes': total_classes,
            'total_loc': total_loc,
            'total_markers': len(self.markers),
            'marker_breakdown': dict(marker_stats),
            'duplicate_filenames': duplicate_count,
            'gitignored_included': gitignored_included,
            'risk': risk_level,
            'analyzed_at': datetime.now().isoformat()
        }
    
    def apply_scope_filter(self):
        """Limit analysis to scope file and connected imports/callers"""
        if not self.scope_abs_path:
            return
        
        scope_key = str(self.scope_abs_path)
        if scope_key not in self.analysis:
            raise ValueError(f"Scope file not analyzed: {self.scope_input}")
        
        queue = deque([scope_key])
        allowed = set()
        
        while queue:
            current = queue.popleft()
            if current in allowed:
                continue
            allowed.add(current)
            
            for neighbor in self.forward_deps.get(current, []):
                if neighbor in self.analysis and neighbor not in allowed:
                    queue.append(neighbor)
            for neighbor in self.reverse_deps.get(current, []):
                if neighbor in self.analysis and neighbor not in allowed:
                    queue.append(neighbor)
        
        if allowed == set(self.analysis.keys()):
            return
        
        # Filter analysis to allowed files
        self.analysis = {path: data for path, data in self.analysis.items() if path in allowed}
        
        allowed_ids = {data['i'] for data in self.analysis.values()}
        for data in self.analysis.values():
            if '←' in data:
                data['←'] = [fid for fid in data['←'] if fid in allowed_ids]
                data['fi'] = len(data['←'])
        
        # Filter markers
        self.markers = [m for m in self.markers if m.get('file_id') in allowed_ids]
        
        # Filter duplicate map to included files
        allowed_rel = {data['lc'] for data in self.analysis.values()}
        filtered_duplicates = {}
        for name, paths in self.duplicate_filenames.items():
            scoped_paths = [p for p in paths if p in allowed_rel]
            if len(scoped_paths) > 1:
                filtered_duplicates[name] = scoped_paths
        self.duplicate_filenames = filtered_duplicates
    
    def to_model_schema(self, full_output):
        """Transform to thin model schema - minimal tokens for LLM"""
        symbols = []
        index = {'file2id': {}, 'sym2id': {}}
        
        for file_data in full_output['files']:
            file_id = file_data['i']
            path = file_data['lc']
            
            # File symbol
            file_sym = {
                'id': file_id,
                'k': 'file',
                'path': path,
                'ls': 1,
                'le': file_data.get('loc', 1)
            }
            if file_data.get('gi'):
                file_sym['gi'] = True
            if file_data.get('imports_files'):
                file_sym['→f'] = self._truncate_list(file_data.get('imports_files', []))
            if file_data.get('imported_by'):
                file_sym['←f'] = self._truncate_list(file_data.get('imported_by', []))
            if file_data.get('criticality'):
                file_sym['criticality'] = file_data.get('criticality')
            symbols.append(file_sym)
            index['file2id'][path] = file_id
            index['sym2id'][file_id] = path
            
            # Function symbols
            for fn in file_data.get('fns', []):
                fn_id = fn['i']
                fn_sym = {
                    'id': fn_id,
                    'k': 'fn',
                    'path': path,
                    'ls': fn['ls'],
                    'le': fn.get('le', fn['ls'])
                }
                calls = fn.get('→', [])
                if calls:
                    fn_sym['→'] = calls[:5]
                if fn.get('io_in'):
                    fn_sym['io_in'] = self._truncate_list(fn['io_in'])
                if fn.get('io_out'):
                    fn_sym['io_out'] = self._truncate_list(fn['io_out'])
                if fn.get('db_tables_in'):
                    fn_sym['db_tables_in'] = self._truncate_list(fn['db_tables_in'])
                if fn.get('db_tables_out'):
                    fn_sym['db_tables_out'] = self._truncate_list(fn['db_tables_out'])
                if fn.get('sym_calls') is not None:
                    fn_sym['sym_calls'] = self._truncate_list(fn.get('sym_calls', []))
                if fn.get('refusals'):
                    fn_sym['refusals'] = fn['refusals']
                if fn.get('sym_called_by') is not None:
                    fn_sym['sym_called_by'] = self._truncate_list(fn.get('sym_called_by', []))
                if fn.get('complexity'):
                    fn_sym['complexity'] = fn.get('complexity')
                if fn.get('route'):
                    fn_sym['route'] = fn.get('route')
                if fn.get('task'):
                    fn_sym['task'] = fn['task']
            
                symbols.append(fn_sym)
                index['sym2id'][fn_id] = f"{path}:{fn['n']}"
            
            # Class symbols
            for cls in file_data.get('cls', []):
                cls_id = cls['i']
                cls_sym = {
                    'id': cls_id,
                    'k': 'cls',
                    'path': path,
                    'ls': cls['ls'],
                    'le': cls.get('le', cls['ls'])
                }
                symbols.append(cls_sym)
                index['sym2id'][cls_id] = f"{path}:{cls['n']}"
        
        # NEW: Add marker symbols
        for marker in full_output.get('markers', []):
            marker_sym = {
                'id': marker['i'],
                'k': 'marker',
                'type': marker['k'],
                'path': marker['file'],
                'ls': marker['ls'],
                'msg': marker['msg']
            }
            symbols.append(marker_sym)
        
        return {
            'schema': 'model-v1',
            'symbols': symbols,
            'index': index,
            'stats': {
                'total_symbols': len(symbols),
                'total_files': full_output['summary']['total_files'],
                'total_markers': full_output['summary']['total_markers']
            }
        }
    
    def to_tool_schema(self, full_output):
        """Transform to rich tool schema - complete metadata"""
        files = []
        markers = []
        index = {'file2id': {}, 'sym2id': {}, 'marker2file': {}}
        
        for file_data in full_output['files']:
            file_path = self.root_dir / file_data['lc']
            file_hash = None
            try:
                with open(file_path, 'rb') as f:
                    file_hash = hashlib.sha256(f.read()).hexdigest()
            except:
                pass
            
            file_entry = {
                'id': file_data['i'],
                'path': file_data['lc'],
                'ls': 1,
                'le': file_data.get('loc', 1),
                'fi': file_data.get('fi', 0)
            }
            
            if file_data.get('gi'):
                file_entry['gi'] = True
            
            if file_hash:
                file_entry['sha256'] = file_hash
            
            if file_data.get('imp_detail'):
                cleaned_imports = []
                for imp in file_data['imp_detail']:
                    clean_imp = {'mod': imp['mod'], 'ls': imp['ls']}
                    if imp.get('as'):
                        clean_imp['as'] = imp['as']
                    cleaned_imports.append(clean_imp)
                if cleaned_imports:
                    file_entry['imports'] = cleaned_imports
            if file_data.get('imports_files'):
                file_entry['imports_files'] = file_data['imports_files']
            if file_data.get('imported_by'):
                file_entry['imported_by'] = file_data['imported_by']
            if file_data.get('data_io'):
                file_entry['data_io'] = file_data['data_io']
            if file_data.get('hardcoded_values'):
                file_entry['hardcoded_values'] = file_data.get('hardcoded_values', [])
            if file_data.get('env_usage'):
                file_entry['env_usage'] = file_data.get('env_usage', [])
            if file_data.get('criticality'):
                file_entry['criticality'] = file_data.get('criticality')
            
            symbols = []
            
            # Functions
            for fn in file_data.get('fns', []):
                fn_entry = {
                    'id': fn['i'],
                    'k': 'fn',
                    'n': fn['n'],
                    'ls': fn['ls'],
                    'le': fn.get('le', fn['ls'])
                }
                if fn.get('p'):
                    fn_entry['p'] = fn['p']
                if fn.get('→'):
                    fn_entry['→'] = fn['→']
                if fn.get('io_in'):
                    fn_entry['io_in'] = fn['io_in']
                if fn.get('io_out'):
                    fn_entry['io_out'] = fn['io_out']
                if fn.get('io_detail'):
                    fn_entry['io_detail'] = fn['io_detail']
                if fn.get('db_tables_in'):
                    fn_entry['db_tables_in'] = fn['db_tables_in']
                if fn.get('db_tables_out'):
                    fn_entry['db_tables_out'] = fn['db_tables_out']
                if fn.get('sym_calls') is not None:
                    fn_entry['sym_calls'] = fn.get('sym_calls', [])
                if fn.get('refusals'):
                    fn_entry['refusals'] = fn['refusals']
                if fn.get('sym_called_by') is not None:
                    fn_entry['sym_called_by'] = fn.get('sym_called_by', [])
                if fn.get('complexity'):
                    fn_entry['complexity'] = fn.get('complexity')
                if fn.get('route'):
                    fn_entry['route'] = fn.get('route')
                if fn.get('task'):
                    fn_entry['task'] = fn['task']
                
                symbols.append(fn_entry)
                index['sym2id'][fn['i']] = f"{file_data['lc']}:{fn['n']}"
            
            # Classes
            for cls in file_data.get('cls', []):
                cls_entry = {
                    'id': cls['i'],
                    'k': 'cls',
                    'n': cls['n'],
                    'ls': cls['ls'],
                    'le': cls.get('le', cls['ls'])
                }
                if cls.get('b') and cls['b']:
                    cls_entry['b'] = cls['b']
                if cls.get('mc') and cls['mc'] > 0:
                    cls_entry['mc'] = cls['mc']
                
                symbols.append(cls_entry)
                index['sym2id'][cls['i']] = f"{file_data['lc']}:{cls['n']}"
            
            if symbols:
                file_entry['symbols'] = symbols
            
            if file_data.get('←'):
                file_entry['←'] = file_data['←']
                file_entry['fi'] = len(file_data['←'])
            
            files.append(file_entry)
            index['file2id'][file_data['lc']] = file_data['i']
        
        # NEW: Build marker entries
        for marker in full_output.get('markers', []):
            marker_entry = {
                'id': marker['i'],
                'k': 'marker',
                'type': marker['k'],
                'file': marker['file'],
                'file_id': marker['file_id'],
                'line': marker['ls'],
                'msg': marker['msg']
            }
            markers.append(marker_entry)
            index['marker2file'][marker['i']] = marker['file_id']
        
        return {
            'schema': 'tool-v1',
            'files': files,
            'markers': markers,
            'index': index,
            'metadata': full_output['metadata'],
            'summary': full_output['summary'],
            'file_graph': full_output.get('file_graph', {}),
            'tables': full_output.get('tables', {}),
            'env_vars': full_output.get('env_vars', {}),
            'routes': full_output.get('routes', []),
            'reactions': full_output.get('reactions', []),
            'time_triggers': full_output.get('time_triggers', []),
            'shared_refusals': full_output.get('shared_refusals', []),
            'absences': full_output.get('absences', {}),
            'docs': {
                'field_guide': full_output.get('field_guide', {}),
                'query_patterns': full_output.get('query_patterns', {})
            }
        }
    
    def run(self, schema='full'):
        """Execute full analysis"""
        duplicates_only = (schema == 'duplicates')
        if duplicates_only and self.scope_input:
            print("Scope filtering is not supported for the duplicates schema.", file=sys.stderr)
            sys.exit(1)
        
        print("Loading .gitignore...", file=sys.stderr)
        self.load_gitignore()
        if not self.respect_gitignore:
            print("Including files matched by .gitignore (they will be flagged with gi=true).", file=sys.stderr)
        
        print("Collecting files...", file=sys.stderr)
        self.collect_files()
        print(f"Found {len(self.files)} files to analyze", file=sys.stderr)
        
        if self.scope_input:
            scope_path = self.resolve_scope_file()
            if not scope_path:
                print(f"Invalid scope file: {self.scope_input}", file=sys.stderr)
                sys.exit(1)
            if str(scope_path) not in self.file_id_map:
                print(f"Scope file not found or unsupported: {self.scope_input}", file=sys.stderr)
                sys.exit(1)
        
        self.duplicate_filenames = self.find_duplicate_filenames()
        if self.duplicate_filenames:
            print(f"Detected {len(self.duplicate_filenames)} duplicate filename(s)", file=sys.stderr)
        else:
            print("No duplicate filenames detected.", file=sys.stderr)
        
        if duplicates_only:
            analyzed_at = datetime.now().isoformat()
            return {
                'schema': 'duplicates-v1',
                'root_dir': str(self.root_dir),
                'respect_gitignore': self.respect_gitignore,
                'traversal_mode': self.traversal_mode,
                'analyzed_at': analyzed_at,
                'total_files_scanned': len(self.all_files),
                'duplicates': self.duplicate_filenames
            }
        
        print("First pass: Analyzing files...", file=sys.stderr)
        for i, file_path in enumerate(self.files, 1):
            print(f"  [{i}/{len(self.files)}] {file_path.relative_to(self.root_dir)}", file=sys.stderr)
            self.analyze_file(file_path)
        
        print("Second pass: Building reverse dependencies...", file=sys.stderr)
        self.build_reverse_dependencies()
        
        if self.scope_input:
            self.apply_scope_filter()
            print(f"Scoped analysis to {len(self.analysis)} file(s) reachable from {self.scope_input}", file=sys.stderr)

        print("Classifying data I/O and database usage...", file=sys.stderr)
        self.classify_data_io()

        print("Building file import graph...", file=sys.stderr)
        self.build_file_graph()

        print("Building symbol call graph...", file=sys.stderr)
        self.build_symbol_call_graph()

        print("Resolving route prefixes...", file=sys.stderr)
        self.resolve_route_prefixes()
        self.aggregate_refusals()
        absences = self.find_absences()

        print(f"Extracted {len(self.markers)} markers (TODO/FIXME/HACK)...", file=sys.stderr)
        
        print("Generating summary...", file=sys.stderr)
        summary = self.generate_summary()

        print("Aggregating database table index...", file=sys.stderr)
        tables_output = self.build_tables_index()
        env_vars_output = {
            name: {
                'files': sorted(list(val['files'])),
                'symbols': sorted(list(val['symbols']))
            }
            for name, val in self.env_index.items()
        }

        print("Computing criticality scores...", file=sys.stderr)
        self.compute_criticality()

        # Build full output
        full_output = {
            'metadata': {
                'version': '1.4.0',
                'schema': 'full',
                'root_dir': str(self.root_dir),
                'analyzed_at': summary['analyzed_at'],
                'respect_gitignore': self.respect_gitignore,
                'traversal_mode': self.traversal_mode
            },
            # 'field_guide': { ... }, # Disabled to save space
            # 'query_patterns': { ... }, # Disabled to save space
            'summary': summary,
            'files': list(self.analysis.values()),
            'markers': self.markers,
            'duplicates': self.duplicate_filenames,
            # 'file_graph': self.file_graph, # Disabled (redundant with files list)
            'tables': tables_output,
            'env_vars': env_vars_output,
            'routes': self.routes,
            'reactions': self.reactions,
            'time_triggers': self.time_triggers,
            'shared_refusals': getattr(self, 'shared_refusals', []),
            'absences': absences
        }
        
        # Return appropriate schema
        if schema == 'model':
            return self.to_model_schema(full_output)
        elif schema == 'tool':
            return self.to_tool_schema(full_output)
        elif schema == 'both':
            return {
                'model': self.to_model_schema(full_output),
                'tool': self.to_tool_schema(full_output)
            }
        else:  # full
            return full_output

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: python analyzer.py <directory> <schema> [respect_gitignore] [scope_file] [traversal_mode]", file=sys.stderr)
        sys.exit(1)
    
    root_dir = sys.argv[1]
    schema = sys.argv[2] if len(sys.argv) > 2 else 'full'
    respect_gitignore = True
    if len(sys.argv) > 3:
        value = sys.argv[3].strip().lower()
        respect_gitignore = value not in ('0', 'false', 'no', 'off')
    
    scope_file = None
    if len(sys.argv) > 4:
        scope_arg = sys.argv[4].strip()
        if scope_arg:
            scope_file = scope_arg
    
    traversal_mode = 'relative'
    if len(sys.argv) > 5:
        traversal_arg = sys.argv[5].strip().lower()
        if traversal_arg:
            traversal_mode = traversal_arg
    
    ignore_patterns_arg = ""
    if len(sys.argv) > 6:
        ignore_patterns_arg = sys.argv[6].strip()
    
    extra_ignores = [p.strip() for p in ignore_patterns_arg.split(',') if p.strip()]
    
    analyzer = CodeAnalyzer(
        root_dir,
        respect_gitignore=respect_gitignore,
        scope_file=scope_file,
        traversal_mode=traversal_mode,
        extra_ignores=extra_ignores
    )
    result = analyzer.run(schema)
    print(json.dumps(result, indent=2))
PYTHON_EOF

log "Running analysis..."

# Run Python analyzer
if [ "$OUTPUT_SCHEMA" = "both" ]; then
    TEMP_COMBINED=$(mktemp /tmp/code_analyzer_combined_XXXXXX)
    LOG_FILE=$(mktemp /tmp/code_analyzer_XXXXXX)
    
    if ! python3 "$TEMP_ANALYZER" "$TARGET_DIR" "both" "$RESPECT_GITIGNORE" "$SCOPE_FILE" "$TRAVERSAL_MODE" "$IGNORE_PATTERNS" > "$TEMP_COMBINED" 2> "$LOG_FILE"; then
        cat "$LOG_FILE" >&2
        rm -f "$TEMP_COMBINED" "$LOG_FILE"
        error "Analysis failed. Check logs above for details."
    fi
    
    if ! jq -e . "$TEMP_COMBINED" >/dev/null 2>&1; then
        cat "$LOG_FILE" >&2
        rm -f "$TEMP_COMBINED" "$LOG_FILE"
        error "Analysis produced invalid JSON. Check logs above."
    fi
    
    MODEL_FILE="${OUTPUT_FILE%.json}-model.json"
    MODEL_TEMP=$(mktemp /tmp/code_analyzer_model_XXXXXX)
    jq '.model' "$TEMP_COMBINED" > "$MODEL_TEMP"

    if jq -e . "$MODEL_TEMP" >/dev/null 2>&1; then
        strip_empty_json "$MODEL_TEMP" || warn "Failed to strip empty values from model schema."
        mv "$MODEL_TEMP" "$MODEL_FILE"
    else
        rm -f "$MODEL_TEMP"
        error "Failed to extract model schema"
    fi

    TOOL_FILE="${OUTPUT_FILE%.json}-tool.json"
    TOOL_TEMP=$(mktemp /tmp/code_analyzer_tool_XXXXXX)
    jq '.tool' "$TEMP_COMBINED" > "$TOOL_TEMP"

    if jq -e . "$TOOL_TEMP" >/dev/null 2>&1; then
        strip_empty_json "$TOOL_TEMP" || warn "Failed to strip empty values from tool schema."
        mv "$TOOL_TEMP" "$TOOL_FILE"
    else
        rm -f "$TOOL_TEMP"
        error "Failed to extract tool schema"
    fi

    rm -f "$TEMP_COMBINED" "$LOG_FILE"

    log "Analysis complete:"
    log "  Model schema: $MODEL_FILE"
    log "  Tool schema: $TOOL_FILE"
else
    OUTPUT_TEMP=$(mktemp /tmp/code_analyzer_output_XXXXXX)
    LOG_FILE=$(mktemp /tmp/code_analyzer_XXXXXX)
    
    if ! python3 "$TEMP_ANALYZER" "$TARGET_DIR" "$OUTPUT_SCHEMA" "$RESPECT_GITIGNORE" "$SCOPE_FILE" "$TRAVERSAL_MODE" "$IGNORE_PATTERNS" > "$OUTPUT_TEMP" 2> "$LOG_FILE"; then
        cat "$LOG_FILE" >&2
        rm -f "$OUTPUT_TEMP" "$LOG_FILE"
        error "Analysis failed. Check logs above for details."
    fi
    
    if ! jq -e . "$OUTPUT_TEMP" >/dev/null 2>&1; then
        cat "$LOG_FILE" >&2
        rm -f "$OUTPUT_TEMP" "$LOG_FILE"
        error "Analysis produced invalid JSON. Check logs above."
    fi

    # Strip empty objects and arrays from output
    log "Stripping empty values from JSON..."
    if ! strip_empty_json "$OUTPUT_TEMP"; then
        warn "Failed to strip empty values; using original output."
    fi

    mv "$OUTPUT_TEMP" "$OUTPUT_FILE"
    
    if [ "$VERBOSE" = true ] && [ -s "$LOG_FILE" ]; then
        log "Analysis log: $LOG_FILE"
    else
        rm -f "$LOG_FILE"
    fi
    
    log "Analysis complete: $OUTPUT_FILE"
fi

# Generate markdown if requested
if [ "$INCLUDE_MARKDOWN" = true ]; then
    if [ "$OUTPUT_SCHEMA" = "duplicates" ]; then
        warn "Markdown generation is not supported for the duplicates schema; skipping."
    else
        if [ "$OUTPUT_SCHEMA" = "both" ]; then
            MARKDOWN_SOURCE="$TOOL_FILE"
        else
            MARKDOWN_SOURCE="$OUTPUT_FILE"
        fi
        
        MARKDOWN_FILE="${MARKDOWN_SOURCE%.json}.md"
        MARKDOWN_LOG=$(mktemp /tmp/code_analyzer_md_XXXXXX)
        
        log "Generating markdown output: $MARKDOWN_FILE"
        
        python3 - "$MARKDOWN_SOURCE" "$MARKDOWN_FILE" 2> "$MARKDOWN_LOG" << 'MARKDOWN_GENERATOR'
import sys
import json
from collections import defaultdict

def generate_markdown(data):
    md = []
    md.append("# Code Repository Analysis Report\n")
    
    # Metadata
    md.append("## Metadata\n")
    meta = data.get('metadata', {})
    md.append(f"- **Root Directory:** `{meta.get('root_dir', 'N/A')}`")
    md.append(f"- **Analyzed:** {meta.get('analyzed_at', 'N/A')}")
    md.append(f"- **Version:** {meta.get('version', 'N/A')}")
    md.append(f"- **Respect .gitignore:** {meta.get('respect_gitignore', True)}")
    md.append(f"- **Traversal Mode:** {meta.get('traversal_mode', 'relative')}\n")
    
    # Summary
    md.append("## Summary\n")
    summary = data.get('summary', {})
    md.append(f"- **Total Files:** {summary.get('total_files', 0)}")
    md.append(f"- **Total Functions:** {summary.get('total_functions', 0)}")
    md.append(f"- **Total Classes:** {summary.get('total_classes', 0)}")
    md.append(f"- **Total LOC:** {summary.get('total_loc', 0):,}")
    md.append(f"- **Risk Level:** {summary.get('risk', 'unknown').upper()}")
    md.append(f"- **Total Markers:** {summary.get('total_markers', 0)}")
    gitignored_included = summary.get('gitignored_included', 0)
    if gitignored_included:
        md.append(f"- **Gitignored Included:** {gitignored_included}")
    md.append("")
    
    # Marker breakdown (NEW)
    if summary.get('marker_breakdown'):
        md.append("### Marker Breakdown\n")
        for marker_type, count in sorted(summary['marker_breakdown'].items()):
            md.append(f"- **{marker_type}:** {count}")
        md.append("")
    
    # Markers section (NEW)
    markers = data.get('markers', [])
    if markers:
        md.append("## Markers (TODO/FIXME/HACK)\n")
        
        # Group by type
        markers_by_type = defaultdict(list)
        for marker in markers:
            markers_by_type[marker['k']].append(marker)
        
        for marker_type in sorted(markers_by_type.keys()):
            md.append(f"### {marker_type}\n")
            for marker in sorted(markers_by_type[marker_type], key=lambda x: (x['file'], x['ls'])):
                file_path = marker['file']
                line = marker['ls']
                msg = marker['msg']
                md.append(f"- **{file_path}:{line}** — {msg}")
            md.append("")
    
    # Files
    md.append("## Files\n")
    files = data.get('files', [])
    
    files_sorted = sorted(files, key=lambda x: x.get('fi', 0), reverse=True)
    
    for file_data in files_sorted:
        md.append(f"### {file_data.get('lc', 'unknown')}\n")
        md.append(f"- **ID:** `{file_data.get('i', '')}`")
        md.append(f"- **Lines:** {file_data.get('loc', 0)}")
        md.append(f"- **Tokens:** ~{file_data.get('tok', 0):,}")
        md.append(f"- **Fan-in:** {file_data.get('fi', 0)} (depended upon by {file_data.get('fi', 0)} files)")
        
        if file_data.get('r'):
            md.append(f"- **⚠️ Risks:** {', '.join(file_data['r'])}")
        
        if file_data.get('u'):
            md.append(f"\n**Imports ({len(file_data['u'])}):**")
            for imp in file_data['u'][:10]:
                md.append(f"  - `{imp}`")
            if len(file_data['u']) > 10:
                md.append(f"  - ... and {len(file_data['u']) - 10} more")
        
        if file_data.get('fns'):
            md.append(f"\n**Functions ({len(file_data['fns'])}):**")
            for fn in file_data['fns'][:5]:
                params = ', '.join(fn.get('p', []))
                md.append(f"  - `{fn.get('n', '')}({params})` (L{fn.get('ls', '')})")
            if len(file_data['fns']) > 5:
                md.append(f"  - ... and {len(file_data['fns']) - 5} more")
        
        if file_data.get('cls'):
            md.append(f"\n**Classes ({len(file_data['cls'])}):**")
            for cls in file_data['cls']:
                bases = ', '.join(cls.get('b', []))
                base_str = f" extends {bases}" if bases else ""
                md.append(f"  - `{cls.get('n', '')}{base_str}` (L{cls.get('ls', '')})")
        
        md.append("")
    
    return '\n'.join(md)

if __name__ == '__main__':
    input_file = sys.argv[1]
    output_file = sys.argv[2]
    
    with open(input_file, 'r') as f:
        data = json.load(f)
    
    markdown = generate_markdown(data)
    
    with open(output_file, 'w') as f:
        f.write(markdown)
    
    print(f"Markdown generated: {output_file}", file=sys.stderr)
MARKDOWN_GENERATOR
    
        if [ $? -eq 0 ] && [ -f "$MARKDOWN_FILE" ]; then
            rm -f "$MARKDOWN_LOG"
        else
            cat "$MARKDOWN_LOG" >&2
            rm -f "$MARKDOWN_LOG"
            warn "Markdown generation failed"
        fi
    fi
fi

# Cleanup
rm -f "$TEMP_ANALYZER"
rm -f /tmp/code_analyzer_*.tmp 2>/dev/null

echo ""
echo -e "${GREEN}✓ Analysis complete!${NC}"

if [ "$OUTPUT_SCHEMA" = "both" ]; then
    echo "  Model schema (thin): ${OUTPUT_FILE%.json}-model.json"
    echo "  Tool schema (rich):  ${OUTPUT_FILE%.json}-tool.json"
else
    echo "  Output: $OUTPUT_FILE"
    echo "  Schema: $OUTPUT_SCHEMA"
fi

if [ "$INCLUDE_MARKDOWN" = true ]; then
    echo "  Markdown: ${OUTPUT_FILE%.json}.md"
fi
echo ""

case "$OUTPUT_SCHEMA" in
    model)
        echo "Model schema optimized for LLM consumption (minimal tokens)."
        echo "Includes: files, functions, classes, and TODO/FIXME/HACK markers."
        ;;
    tool)
        echo "Tool schema with complete metadata for post-processing."
        echo "Includes: detailed symbols, markers, imports, and reverse dependencies."
        ;;
    both)
        echo "Generated both schemas:"
        echo "  - Model: for LLM (minimal tokens + markers)"
        echo "  - Tool: for tools (complete metadata + markers)"
        ;;
    full)
        echo "Full schema with all analysis details including markers."
        ;;
    duplicates)
        echo "Duplicate filename schema listing each repeated basename and its paths."
        ;;
esac
