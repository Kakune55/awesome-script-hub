#!/usr/bin/env bash
set -Eeuo pipefail

# Based on https://github.com/bihell/fio (MIT License).
# Copyright (c) 2023 Haseo Chen.

SIZE="${FIO_SIZE:-1g}"
RUNTIME="${FIO_RUNTIME:-60s}"
TYPE="default"
TEST_DIR=""
WORK_DIR=""

log()  { printf '[INFO] %s\n' "$*"; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法：
  bash script.sh <测试目录> [fast] [ssd|all]

参数：
  fast        每个项目运行 10 秒
  ssd         运行 SSD/NVMe 测试项目
  all         运行默认和 SSD/NVMe 全部测试项目
  -h, --help  显示帮助

环境变量：
  FIO_SIZE     每个任务的测试文件大小，默认 1g
  FIO_RUNTIME  每个项目的运行时间，默认 60s
EOF
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" && "$WORK_DIR" == "$TEST_DIR"/.fio-mark.* ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}

trap cleanup EXIT

parse_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            fast)
                RUNTIME="10s"
                ;;
            ssd)
                TYPE="ssd"
                ;;
            all)
                TYPE="all"
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                [[ -d "$arg" ]] || die "测试目录不存在或参数无效：$arg"
                [[ -z "$TEST_DIR" ]] || die "只能指定一个测试目录"
                TEST_DIR="$arg"
                ;;
        esac
    done

    [[ -n "$TEST_DIR" ]] || die "未指定测试目录。使用 --help 查看用法"
    TEST_DIR="$(cd -- "$TEST_DIR" && pwd -P)"
    [[ -w "$TEST_DIR" ]] || die "当前用户无权写入测试目录：$TEST_DIR"
}

ensure_dependencies() {
    local missing=()
    local command_name

    for command_name in fio jq; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    ((${#missing[@]})) || return 0

    log "缺少依赖：${missing[*]}"
    [[ "$EUID" -eq 0 ]] || die "自动安装依赖需要 root 权限；请以 root 运行，或由执行者使用 sudo 重跑"

    if command -v apt-get >/dev/null 2>&1; then
        log "检测到 apt-get，正在安装依赖"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y "${missing[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        log "检测到 dnf，正在安装依赖"
        dnf install -y "${missing[@]}"
    else
        die "未检测到 apt-get 或 dnf，请手动安装：${missing[*]}"
    fi

    for command_name in "${missing[@]}"; do
        command -v "$command_name" >/dev/null 2>&1 || die "依赖安装后仍不可用：$command_name"
    done
}

run_benchmark() {
    local result_file query
    local -a fio_args

    WORK_DIR="$(mktemp -d "$TEST_DIR/.fio-mark.XXXXXXXX")"
    result_file="$WORK_DIR/result.json"

    fio_args=(
        fio
        "--directory=$WORK_DIR"
        "--size=$SIZE"
        "--runtime=$RUNTIME"
        --time_based
        --ramp_time=5s
        --ioengine=libaio
        --direct=1
        --stonewall
        --verify=0
        --group_reporting=1
        --output-format=json
        "--output=$result_file"
        '--filename_format=$jobname.$jobnum'
        --name=read,RND4K-Q1T1 --rw=randread --iodepth=1 --bs=4k --numjobs=1
        --name=write,RND4K-Q1T1 --rw=randwrite --iodepth=1 --bs=4k --numjobs=1
        --name=read,SEQ1M-Q8T1 --rw=read --iodepth=8 --bs=1M --numjobs=1
        --name=write,SEQ1M-Q8T1 --rw=write --iodepth=8 --bs=1M --numjobs=1
    )

    case "$TYPE" in
        default)
            log "执行默认测试"
            fio_args+=(
                --name=read,SEQ1M-Q1T1 --rw=read --iodepth=1 --bs=1M --numjobs=1
                --name=write,SEQ1M-Q1T1 --rw=write --iodepth=1 --bs=1M --numjobs=1
                --name=read,RND4K-Q32T1 --rw=randread --iodepth=32 --bs=4k --numjobs=1
                --name=write,RND4K-Q32T1 --rw=randwrite --iodepth=32 --bs=4k --numjobs=1
            )
            query="$JQ_GENERAL $JQ_DEFAULT"
            ;;
        ssd)
            log "执行 SSD/NVMe 测试"
            fio_args+=(
                --name=read,SEQ128K-Q32T1 --rw=read --iodepth=32 --bs=128k --numjobs=1
                --name=write,SEQ128K-Q32T1 --rw=write --iodepth=32 --bs=128k --numjobs=1
                --name=read,RND4K-Q32T16 --rw=randread --iodepth=32 --bs=4k --numjobs=16
                --name=write,RND4K-Q32T16 --rw=randwrite --iodepth=32 --bs=4k --numjobs=16
            )
            query="$JQ_GENERAL $JQ_NVME"
            ;;
        all)
            log "执行全部测试"
            fio_args+=(
                --name=read,SEQ1M-Q1T1 --rw=read --iodepth=1 --bs=1M --numjobs=1
                --name=write,SEQ1M-Q1T1 --rw=write --iodepth=1 --bs=1M --numjobs=1
                --name=read,RND4K-Q32T1 --rw=randread --iodepth=32 --bs=4k --numjobs=1
                --name=write,RND4K-Q32T1 --rw=randwrite --iodepth=32 --bs=4k --numjobs=1
                --name=read,SEQ128K-Q32T1 --rw=read --iodepth=32 --bs=128k --numjobs=1
                --name=write,SEQ128K-Q32T1 --rw=write --iodepth=32 --bs=128k --numjobs=1
                --name=read,RND4K-Q32T16 --rw=randread --iodepth=32 --bs=4k --numjobs=16
                --name=write,RND4K-Q32T16 --rw=randwrite --iodepth=32 --bs=4k --numjobs=16
            )
            query="$JQ_GENERAL $JQ_DEFAULT $JQ_NVME"
            ;;
    esac

    printf '测试目录：%s\n文件大小：%s\n单项时长：%s\n\n' "$TEST_DIR" "$SIZE" "$RUNTIME"
    "${fio_args[@]}"
    print_results "$query" "$result_file"
}

print_results() {
    local query="$1"
    local result_file="$2"

    jq -r "$query" "$result_file" |
        awk -F',' '
        {
            key = $2
            if ($1 == "read" && $3 == "read") {
                if ($4 == "bw") {
                    if (!(key in seen)) {
                        order[++count] = key
                        seen[key] = 1
                    }
                    read_bw[key] = $5
                }
                if ($4 == "io") read_io[key] = $5
                if ($4 == "lat_ns") read_lat_ns[key] = $5
            }
            if ($1 == "write" && $3 == "write") {
                if ($4 == "bw") write_bw[key] = $5
                if ($4 == "io") write_io[key] = $5
                if ($4 == "lat_ns") write_lat_ns[key] = $5
            }
        }
        END {
            printf("%17s %15s %15s %15s %15s %15s %15s\n", "", "Read [MB/s]", "Read [IOPS]", "Read [LAT_ns]", "Write [MB/s]", "Write [IOPS]", "Write [LAT_ns]")
            for (i = 1; i <= count; i++) {
                key = order[i]
                printf("%17s %15s %15s %15s %15s %15s %15s\n", key, read_bw[key], read_io[key], read_lat_ns[key], write_bw[key], write_io[key], write_lat_ns[key])
            }
        }'
}

JQ_GENERAL='def read_bw(name): [.jobs[] | select(.jobname == name).read.bw] | add / 1024 | floor | tostring;
def write_bw(name): [.jobs[] | select(.jobname == name).write.bw] | add / 1024 | floor | tostring;
def read_iops(name): [.jobs[] | select(.jobname == name).read.iops] | add | floor | tostring;
def write_iops(name): [.jobs[] | select(.jobname == name).write.iops] | add | floor | tostring;
def read_lat_ns(name): [.jobs[] | select(.jobname == name).read.lat_ns.mean] | add | floor | tostring;
def write_lat_ns(name): [.jobs[] | select(.jobname == name).write.lat_ns.mean] | add | floor | tostring;
def job_summary(name): name + "," + "read,bw" + "," + read_bw(name), name + "," + "write,bw" + "," + write_bw(name), name + "," + "read,io" + "," + read_iops(name), name + "," + "write,io" + "," + write_iops(name), name + "," + "read,lat_ns" + "," + read_lat_ns(name), name + "," + "write,lat_ns" + "," + write_lat_ns(name);
job_summary("read,RND4K-Q1T1"), job_summary("write,RND4K-Q1T1"),
job_summary("read,SEQ1M-Q8T1"), job_summary("write,SEQ1M-Q8T1")'

JQ_DEFAULT=', job_summary("read,SEQ1M-Q1T1"), job_summary("write,SEQ1M-Q1T1"),
job_summary("read,RND4K-Q32T1"), job_summary("write,RND4K-Q32T1")'

JQ_NVME=', job_summary("read,SEQ128K-Q32T1"), job_summary("write,SEQ128K-Q32T1"),
job_summary("read,RND4K-Q32T16"), job_summary("write,RND4K-Q32T16")'

parse_args "$@"
ensure_dependencies
run_benchmark
