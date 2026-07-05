#!/usr/bin/env bash
# ===================================
# DSA 本地开发启动脚本（可选 AlphaSift 来源）
# ===================================
#
# 用法：
#   ./scripts/run-dev-with-alphasift.sh [--local|--bundled] [--install-only|--status] [--] [main.py 参数...]
#
# 未指定 --local / --bundled 时会交互式选择 AlphaSift 来源。
# 默认启动参数为：--serve-only
#
# 环境变量：
#   ALPHASIFT_LOCAL_PATH  本地 alphasift 仓库路径（默认：<repo>/../alphasift）
#   PYTHON_BIN            Python 解释器（默认：python3）
#
# 示例：
#   ./scripts/run-dev-with-alphasift.sh --local
#   ./scripts/run-dev-with-alphasift.sh --bundled -- --serve-only --port 8000
#   ALPHASIFT_LOCAL_PATH=/path/to/alphasift ./scripts/run-dev-with-alphasift.sh --local --install-only
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "${PYTHON_BIN}" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
  else
    PYTHON_BIN="python"
  fi
fi

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
  error "未找到 Python。请安装 Python 3.10+ 后重试。"
  exit 1
fi

DEFAULT_LOCAL_PATH="$(cd "${REPO_ROOT}/.." && pwd)/alphasift"
ALPHASIFT_LOCAL_PATH="${ALPHASIFT_LOCAL_PATH:-${DEFAULT_LOCAL_PATH}}"

MODE=""
INSTALL_ONLY=0
SHOW_STATUS=0
MAIN_ARGS=()

usage() {
  cat <<'EOF'
用法: ./scripts/run-dev-with-alphasift.sh [选项] [-- main.py 参数...]

选项:
  --local, -l         使用本地 editable 安装（pip install -e <path>）
  --bundled, -b       使用 requirements.txt 中 pin 的 AlphaSift 版本
  --install-only      仅安装/切换 AlphaSift，不启动 DSA
  --status, -s        显示当前 Python 环境中的 AlphaSift 来源
  -h, --help          显示本帮助

未指定 --local / --bundled 时会交互式选择。
默认 main.py 参数：--serve-only

环境变量:
  ALPHASIFT_LOCAL_PATH  本地 alphasift 仓库路径
  PYTHON_BIN            Python 解释器
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local|-l)
      MODE="local"
      shift
      ;;
    --bundled|-b)
      MODE="bundled"
      shift
      ;;
    --install-only)
      INSTALL_ONLY=1
      shift
      ;;
    --status|-s)
      SHOW_STATUS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      MAIN_ARGS+=("$@")
      break
      ;;
    *)
      MAIN_ARGS+=("$1")
      shift
      ;;
  esac
done

resolve_bundled_spec() {
  local spec
  spec="$(grep -E '^git\+.*alphasift' "${REPO_ROOT}/requirements.txt" | head -n 1 || true)"
  if [[ -z "${spec}" ]]; then
    error "requirements.txt 中未找到 AlphaSift git pin。"
    exit 1
  fi
  printf '%s' "${spec}"
}

validate_local_path() {
  if [[ ! -d "${ALPHASIFT_LOCAL_PATH}" ]]; then
    error "本地 AlphaSift 路径不存在：${ALPHASIFT_LOCAL_PATH}"
    error "请设置 ALPHASIFT_LOCAL_PATH 或把仓库放在 ${DEFAULT_LOCAL_PATH}"
    exit 1
  fi
  if [[ ! -f "${ALPHASIFT_LOCAL_PATH}/alphasift/dsa_adapter.py" ]]; then
    error "本地路径缺少 alphasift/dsa_adapter.py：${ALPHASIFT_LOCAL_PATH}"
    exit 1
  fi
}

show_alphasift_status() {
  "${PYTHON_BIN}" - <<'PY'
import importlib.util
import pathlib
import sys

try:
    import alphasift
    import alphasift.dsa_adapter as adapter
except Exception as exc:
    print(f"alphasift: unavailable ({exc})")
    sys.exit(1)

adapter_path = pathlib.Path(adapter.__file__).resolve()
print(f"alphasift package: {pathlib.Path(alphasift.__file__).resolve()}")
print(f"dsa_adapter:       {adapter_path}")

spec = importlib.util.find_spec("alphasift")
origin = getattr(spec, "origin", None) if spec else None
submodule_locations = getattr(spec, "submodule_search_locations", None) if spec else None
if submodule_locations:
    locations = [str(pathlib.Path(item).resolve()) for item in submodule_locations]
    print(f"package locations: {', '.join(locations)}")

try:
    import importlib.metadata as metadata
except ImportError:
    import importlib_metadata as metadata  # type: ignore

try:
    dist = metadata.distribution("alphasift")
    editable = (dist.read_text("direct_url.json") or "").strip()
    if editable:
        print("install mode:      editable (direct_url.json present)")
    else:
        print("install mode:      site-packages")
except Exception:
    print("install mode:      unknown")

try:
    status = adapter.get_status()
    if isinstance(status, dict):
        version = status.get("version") or "unknown"
        available = status.get("available")
        print(f"adapter status:    available={available}, version={version}")
except Exception as exc:
    print(f"adapter status:    get_status() failed ({exc})")
PY
}

install_local_alphasift() {
  validate_local_path
  info "安装本地 editable AlphaSift：${ALPHASIFT_LOCAL_PATH}"
  "${PYTHON_BIN}" -m pip install -e "${ALPHASIFT_LOCAL_PATH}"
}

install_bundled_alphasift() {
  local bundled_spec
  bundled_spec="$(resolve_bundled_spec)"
  info "安装 requirements.txt pin 的 AlphaSift：${bundled_spec}"
  "${PYTHON_BIN}" -m pip install --upgrade --force-reinstall "${bundled_spec}"
}

verify_alphasift_adapter() {
  info "校验 alphasift.dsa_adapter ..."
  if ! "${PYTHON_BIN}" -c "import alphasift.dsa_adapter" >/dev/null 2>&1; then
    error "当前 Python 环境无法导入 alphasift.dsa_adapter。"
    exit 1
  fi
  success "AlphaSift 适配层可导入。"
  echo ""
  show_alphasift_status
  echo ""
}

prompt_mode() {
  echo ""
  echo "请选择 AlphaSift 来源："
  echo "  1) local   - 本地 editable（${ALPHASIFT_LOCAL_PATH}）"
  echo "  2) bundled - requirements.txt 固定版本"
  echo "  3) skip    - 不切换，使用当前 Python 环境已安装版本"
  echo ""
  read -r -p "输入 1/2/3 [默认 1]: " choice
  case "${choice:-1}" in
    1|local|l|L)
      MODE="local"
      ;;
    2|bundled|b|B)
      MODE="bundled"
      ;;
    3|skip|s|S)
      MODE="skip"
      ;;
    *)
      error "无效选择：${choice}"
      exit 1
      ;;
  esac
}

apply_mode() {
  case "${MODE}" in
    local)
      install_local_alphasift
      ;;
    bundled)
      install_bundled_alphasift
      ;;
    skip)
      info "跳过 AlphaSift 安装切换。"
      ;;
    "")
      prompt_mode
      apply_mode
      return
      ;;
    *)
      error "未知模式：${MODE}"
      exit 1
      ;;
  esac
}

cd "${REPO_ROOT}"

if [[ "${SHOW_STATUS}" -eq 1 ]]; then
  show_alphasift_status
  exit 0
fi

if [[ -z "${MODE}" ]]; then
  prompt_mode
fi

apply_mode
verify_alphasift_adapter

if [[ "${INSTALL_ONLY}" -eq 1 ]]; then
  success "AlphaSift 已就绪。未启动 DSA。"
  exit 0
fi

if [[ "${#MAIN_ARGS[@]}" -eq 0 ]]; then
  MAIN_ARGS=(--serve-only)
fi

info "启动 DSA：${PYTHON_BIN} main.py ${MAIN_ARGS[*]}"
warn "请勿在 Web 设置页点击 AlphaSift「修复安装」，否则会覆盖当前选择的版本。"
exec "${PYTHON_BIN}" "${REPO_ROOT}/main.py" "${MAIN_ARGS[@]}"
