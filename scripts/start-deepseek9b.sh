#!/bin/bash
# start-deepseek9b.sh - DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic (Q4_K_M) 本地服务
#
# 设计目标：在 8GB 显存的笔记本上稳定跑一个 9B 蒸馏模型，并接入 DeepSeek Harness。
#
# 三个必须知道的点（都是实测踩出来的）：
#
#   1. 显存红线
#      纯文本 ctx=49152 -> 6768 MiB
#      带视觉 ctx=32768 -> 7449 MiB（mmproj 约 +0.9 GB）
#      8GB 卡（实际 8188 MiB）上带视觉只能用 32K；想上 48K 必须去掉 -mm。
#
#   2. --parallel 会切分上下文
#      --parallel 2 会把 -c 32768 平分成每槽 16384。
#      DSH 默认 maxTokens 要 32768，槽位一小就会判定超限。所以这里固定 --parallel 1。
#
#   3. 进程存活
#      WSL 会在调用返回后回收会话树。必须 setsid + nohup + disown 三重脱离，
#      否则你测着一切正常，命令一结束服务就没了。daemon 子命令再加一层自动拉起。
#
# 用法:
#   ./start-deepseek9b.sh start [ctx]    # 默认 32768
#   ./start-deepseek9b.sh daemon [ctx]   # 守护：掉线 5 秒后自动重拉
#   ./start-deepseek9b.sh stop
#   ./start-deepseek9b.sh status
#   ./start-deepseek9b.sh test

set -u

# ---------- 可按需修改的配置 ----------
MODEL_DIR="${MODEL_DIR:-$HOME/models/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic}"
MODEL="${MODEL:-$MODEL_DIR/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic-Q4_K_M.gguf}"
MMPROJ="${MMPROJ:-$MODEL_DIR/mmproj-DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic-f16.gguf}"
LLAMA_DIR="${LLAMA_DIR:-$HOME/bonsai/llama-prism-b10743-adfffbe}"
NV="${NV:-$HOME/miniconda3/envs/dsh-bonsai/lib/python3.11/site-packages/nvidia}"
PORT="${PORT:-8440}"
ALIAS="${ALIAS:-deepseek9b}"
LOG="${LOG:-$HOME/bonsai/deepseek9b.log}"
PIDFILE="${PIDFILE:-$HOME/bonsai/deepseek9b.pid}"
DAEMONLOG="${DAEMONLOG:-$HOME/bonsai/deepseek9b-daemon.log}"
# --------------------------------------

export LD_LIBRARY_PATH="$NV/cublas/lib:$NV/cuda_runtime/lib:$NV/cuda_nvrtc/lib:/usr/lib/wsl/lib:$LLAMA_DIR"

CTX="${2:-32768}"

_preflight() {
    local fail=0
    [ -x "$LLAMA_DIR/llama-server" ] || {
        echo "ERROR: 找不到 llama-server: $LLAMA_DIR/llama-server"
        echo "       设置 LLAMA_DIR 指向你的 llama.cpp 目录"
        fail=1
    }
    [ -f "$MODEL" ] || {
        echo "ERROR: 找不到模型: $MODEL"
        echo "       先跑 scripts/download-model.py，或设置 MODEL_DIR=/已有/目录"
        fail=1
    }
    if [ ! -f "$MMPROJ" ]; then
        echo "WARN: 没有 mmproj，将以纯文本模式启动（识图不可用）"
        echo "      想启用识图：scripts/download-model.py --with-mmproj"
    fi
    return $fail
}

_launch() {
    local mmargs=()
    [ -f "$MMPROJ" ] && mmargs=(-mm "$MMPROJ")

    cd "$LLAMA_DIR" || return 1
    setsid nohup bash -c "
        exec '$LLAMA_DIR/llama-server' \
            -m '$MODEL' \
            ${mmargs[*]:+$(printf -- "-mm '%s'" "$MMPROJ")} \
            --host 0.0.0.0 --port $PORT \
            -ngl 99 -fa on -c $CTX \
            --cache-type-k q4_0 --cache-type-v q4_0 \
            --parallel 1 --fit off --jinja --no-warmup \
            --alias $ALIAS
    " >> "$LOG" 2>&1 < /dev/null &
    local pid=$!
    echo "$pid" > "$PIDFILE" 2>/dev/null || true
    disown 2>/dev/null || true
    echo "$pid"
}

_wait_ready() {
    for _ in $(seq 1 40); do
        sleep 3
        if curl -sf -m 2 "http://127.0.0.1:${PORT}/v1/models" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

cmd_start() {
    if ! _preflight; then
        echo
        echo "启动中止。请先准备模型，或设置 MODEL_DIR 指向已有目录："
        echo "  MODEL_DIR=/path/to/models bash $0 start $CTX"
        exit 1
    fi
    pkill -f "llama-server.*DeepSeek-V4-Pro-Qwen3.5-9B" 2>/dev/null || true
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
    sleep 3

    echo "启动 $ALIAS  ctx=$CTX  port=$PORT"
    [ -f "$MMPROJ" ] && echo "  视觉: $(basename "$MMPROJ")" || echo "  纯文本模式"

    local pid
    pid=$(_launch)

    if _wait_ready; then
        echo "  就绪 :$PORT  (PID $pid)"
        command -v nvidia-smi >/dev/null && \
            nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader | sed 's/^/  VRAM: /'
        return 0
    fi
    echo "  ERROR: 120 秒内未就绪，日志尾部："
    tail -12 "$LOG"
    return 1
}

cmd_daemon() {
    if ! _preflight; then
        echo
        echo "守护模式中止。请先准备模型，或设置 MODEL_DIR。"
        exit 1
    fi
    echo "守护模式启动（每 5 秒探活，掉线自动重拉）"
    echo "  日志: $DAEMONLOG"
    setsid nohup bash -c "
        while true; do
            if ! curl -sf -m 3 http://127.0.0.1:$PORT/v1/models >/dev/null 2>&1; then
                echo \"\$(date '+%F %T')  服务不可达，重启\" >> $DAEMONLOG
                pkill -f 'llama-server.*DeepSeek-V4-Pro-Qwen3.5-9B' 2>/dev/null
                sleep 2
                cd '$LLAMA_DIR'
                $( [ -f "$MMPROJ" ] && printf -- "-mm '%s'" "$MMPROJ" ) \
                ./llama-server -m '$MODEL' \
                    $( [ -f "$MMPROJ" ] && printf -- "-mm '%s'" "$MMPROJ" ) \
                    --host 0.0.0.0 --port $PORT \
                    -ngl 99 -fa on -c $CTX \
                    --cache-type-k q4_0 --cache-type-v q4_0 \
                    --parallel 1 --fit off --jinja --no-warmup \
                    --alias $ALIAS >> $LOG 2>&1
            fi
            sleep 5
        done
    " >> "$DAEMONLOG" 2>&1 < /dev/null &
    echo "  守护 PID: $!"
    disown 2>/dev/null || true
    sleep 6
    cmd_status
}

cmd_stop() {
    pkill -f "llama-server.*DeepSeek-V4-Pro-Qwen3.5-9B" 2>/dev/null || true
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
    sleep 3
    echo "已停止"
}

cmd_status() {
    command -v nvidia-smi >/dev/null && \
        nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader
    if curl -sf -m 2 "http://127.0.0.1:${PORT}/v1/models" >/dev/null 2>&1; then
        echo "  :$PORT online"
        ps aux | grep 'llama-server.*DeepSeek' | grep -v grep \
            | awk '{printf "  PID %s  RSS %dMB\n", $2, $6/1024}'
    else
        echo "  :$PORT offline"
    fi
}

cmd_test() {
    curl -s -m 180 "http://127.0.0.1:${PORT}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d '{"model":"'"$ALIAS"'","messages":[{"role":"user","content":"17 乘 23 等于多少？直接给答案。"}],"max_tokens":600}' \
        | head -c 800
    echo
}

case "${1:-}" in
    start)  cmd_start ;;
    daemon) cmd_daemon ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    test)   cmd_test ;;
    *)
        echo "用法: $0 {start [ctx]|daemon [ctx]|stop|status|test}"
        exit 1
        ;;
esac
