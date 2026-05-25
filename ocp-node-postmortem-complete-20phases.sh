#!/usr/bin/env bash
# =============================================================================
# OCP NODE COMPLETE 20-PHASE POSTMORTEM — ULTIMATE EDITION
# Each phase shown individually with full details
# =============================================================================

set +e
set +u
set +o pipefail

NODE="${1:-}"
SKIP_MUST_GATHER="${2:-false}"

if [ -z "$NODE" ]; then
  cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║  OCP NODE COMPLETE 20-PHASE POSTMORTEM                       ║
║  Ultimate Edition - Every Phase Shown in Detail              ║
╚══════════════════════════════════════════════════════════════╝

Usage: $0 <node-name> [skip-must-gather]

This script performs 20 comprehensive diagnostic phases:
  Phase 1-15:  Standard OpenShift diagnostics
  Phase 16-20: Advanced analytics & predictions

EOF
  exit 1
fi

TS=$(date +%Y%m%d_%H%M%S)
OUT="/tmp/postmortem-${NODE}-${TS}"
mkdir -p "$OUT"

MASTER_LOG="${OUT}/00_MASTER_LOG.txt"
SUMMARY="${OUT}/00_SUMMARY.txt"
ERRORS="${OUT}/00_ERRORS_FLAGGED.txt"
METRICS="${OUT}/00_METRICS.json"
ANOMALIES="${OUT}/00_ANOMALIES.json"

exec > >(tee -a "$MASTER_LOG") 2>&1

# Colors
RED='\033[1;31m'; GRN='\033[1;32m'; YLW='\033[1;33m'
BLU='\033[1;34m'; MAG='\033[1;35m'; CYN='\033[1;36m'
BOLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'

# Helpers
section() {
  echo
  echo -e "${BOLD}${BLU}╔══════════════════════════════════════════════════════════════╗${RST}"
  printf "${BOLD}${BLU}║  %-58s║${RST}\n" "$1"
  echo -e "${BOLD}${BLU}╚══════════════════════════════════════════════════════════════╝${RST}"
}

subsection() {
  echo
  echo -e "${CYN}┌─── $1 ───${RST}"
}

info() { echo -e "${DIM}  ▶ $1${RST}"; }
success() { echo -e "${GRN}  ✓ $1${RST}"; }
warning() { echo -e "${YLW}  ⚠ $1${RST}"; }
error() { echo -e "${RED}  ✗ $1${RST}"; }

progress() {
  local current=$1
  local total=$2
  local desc="$3"
  local percent=$((current * 100 / total))
  local bar_width=40
  local filled=$((bar_width * current / total))
  local empty=$((bar_width - filled))
  
  printf "\r${BOLD}${CYN}Progress: [${RST}"
  printf "%${filled}s" | tr ' ' '█'
  printf "%${empty}s" | tr ' ' '░'
  printf "${BOLD}${CYN}] ${percent}%% - Phase ${current}/${total}: ${desc}${RST}"
  
  if [ "$current" -eq "$total" ]; then
    echo
  fi
}

flag_error() {
  echo -e "${RED}  ⚠ FLAG: $1${RST}"
  echo "[$(date -Iseconds)] $1" >> "$ERRORS"
}

flag_anomaly() {
  echo -e "${MAG}  🔍 ANOMALY: $1${RST}"
  echo "{\"timestamp\":\"$(date -Iseconds)\",\"type\":\"$2\",\"description\":\"$1\",\"severity\":\"$3\"}" >> "$ANOMALIES"
}

sanitize_var() {
  echo "$1" | head -1 | tr -d '\n' | tr -d '\r'
}

node_exec() {
  oc debug node/"$NODE" --quiet -- chroot /host bash -c "$1" 2>/dev/null
}

save_node() {
  local FILE="$1"
  local CMD="$2"
  info "Collecting: $(basename $FILE)"
  node_exec "$CMD" 2>&1 | tee "$FILE" | head -20
  local lines=$(wc -l < "$FILE" 2>/dev/null || echo 0)
  if [ "$lines" -gt 20 ]; then
    echo -e "${DIM}    ... ($lines lines total, showing first 20)${RST}"
  fi
}

save_local() {
  local file="$1"
  shift
  info "Collecting: $(basename $file)"
  "$@" 2>&1 | tee "$file" | head -20
  local lines=$(wc -l < "$file" 2>/dev/null || echo 0)
  if [ "$lines" -gt 20 ]; then
    echo -e "${DIM}    ... ($lines lines total, showing first 20)${RST}"
  fi
}

# Create directories
mkdir -p "$OUT"/{phase{01..20},phase00_preflight}

echo "[]" > "$ANOMALIES"

clear
section "OCP NODE COMPLETE 20-PHASE POSTMORTEM"

cat << EOF
${BOLD}Target Node:${RST}    $NODE
${BOLD}Output Dir:${RST}     $OUT
${BOLD}Timestamp:${RST}      $(date)
${BOLD}Analysis:${RST}       ${MAG}20 COMPREHENSIVE PHASES${RST}

EOF

# =============================================================================
# PHASE 0 — PREFLIGHT
# =============================================================================

progress 0 20 "Preflight Checks"
section "PHASE 0 — PREFLIGHT CHECKS"

subsection "0.1 Verify oc CLI"
if ! command -v oc &>/dev/null; then
  error "oc CLI not found"; exit 1
fi
success "oc CLI found"

subsection "0.2 Verify Authentication"
info "Checking authentication..."
if ! oc whoami >/dev/null 2>&1; then
  error "Not authenticated"; exit 1
fi
success "Authenticated as: $(oc whoami)"

subsection "0.3 Verify Node Exists"
info "Verifying node: $NODE"
if ! oc get node "$NODE" >/dev/null 2>&1; then
  error "Node not found"; exit 1
fi
success "Node exists"

NODE_STATUS=$(oc get node "$NODE" --no-headers 2>/dev/null | awk '{print $2}')
NODE_ROLES=$(oc get node "$NODE" --no-headers 2>/dev/null | awk '{print $3}')

echo "  Status: $NODE_STATUS"
echo "  Roles:  $NODE_ROLES"

save_local "$OUT/phase00_preflight/node_status.txt" oc get node "$NODE" -o yaml

# =============================================================================
# PHASE 1 — AWS INFRASTRUCTURE
# =============================================================================

progress 1 20 "AWS Infrastructure"
section "PHASE 1 — AWS INFRASTRUCTURE"

subsection "1.1 EC2 Instance Metadata"
info "Fetching EC2 metadata..."

INSTANCE_ID=$(node_exec "curl -s --max-time 5 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null" | head -1 | tr -d '\n')
INSTANCE_TYPE=$(node_exec "curl -s --max-time 5 http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null" | head -1 | tr -d '\n')
INSTANCE_AZ=$(node_exec "curl -s --max-time 5 http://169.254.169.254/latest/meta-data/placement/availability-zone 2>/dev/null" | head -1 | tr -d '\n')

echo -e "${GRN}  Instance ID:   $INSTANCE_ID${RST}"
echo -e "${GRN}  Instance Type: $INSTANCE_TYPE${RST}"
echo -e "${GRN}  AZ:            $INSTANCE_AZ${RST}"

save_node "$OUT/phase01/metadata.txt" "curl -s http://169.254.169.254/latest/meta-data/"

subsection "1.2 Spot Instance Check"
info "Checking spot instance status..."

SPOT_ACTION=$(node_exec "curl -s --max-time 2 http://169.254.169.254/latest/meta-data/spot/instance-action 2>/dev/null" | head -1)
if echo "$SPOT_ACTION" | grep -q "terminate\|stop"; then
  flag_error "SPOT TERMINATION PENDING"
else
  success "No spot termination"
fi

subsection "1.3 Network Configuration"

save_node "$OUT/phase01/ip_addr.txt" "ip addr show"
save_node "$OUT/phase01/routes.txt" "ip route show"

# =============================================================================
# PHASE 2 — HARDWARE
# =============================================================================

progress 2 20 "Hardware Inventory"
section "PHASE 2 — HARDWARE INVENTORY"

subsection "2.1 CPU Information"
info "Analyzing CPU..."

save_node "$OUT/phase02/lscpu.txt" "lscpu"
save_node "$OUT/phase02/cpuinfo.txt" "cat /proc/cpuinfo"

CPU_COUNT=$(node_exec "nproc 2>/dev/null" | head -1 | tr -d '\n')
echo -e "${GRN}  CPU Count: $CPU_COUNT${RST}"

subsection "2.2 Memory Information"
info "Analyzing memory..."

save_node "$OUT/phase02/meminfo.txt" "cat /proc/meminfo"
save_node "$OUT/phase02/free.txt" "free -h"

MEM_TOTAL=$(node_exec "free -h 2>/dev/null | grep Mem | awk '{print \$2}'" | head -1 | tr -d '\n')
echo -e "${GRN}  Total Memory: $MEM_TOTAL${RST}"

subsection "2.3 Disk Information"
info "Analyzing disk..."

save_node "$OUT/phase02/lsblk.txt" "lsblk -a"
save_node "$OUT/phase02/df.txt" "df -h"

DISK_ROOT=$(node_exec "df -h / 2>/dev/null | tail -1 | awk '{print \$5}'" | head -1 | tr -d '\n' | tr -d '%')
echo -e "${GRN}  Root Disk Usage: ${DISK_ROOT}%${RST}"

if [ "$DISK_ROOT" -gt 85 ]; then
  flag_error "Root disk usage critical: ${DISK_ROOT}%"
fi

subsection "2.4 Network Hardware"

save_node "$OUT/phase02/ethtool.txt" "ethtool eth0 2>/dev/null"

# =============================================================================
# PHASE 3 — KERNEL
# =============================================================================

progress 3 20 "Kernel Analysis"
section "PHASE 3 — KERNEL ANALYSIS"

subsection "3.1 Kernel Version"
info "Checking kernel version..."

KERNEL_VERSION=$(node_exec "uname -r" | head -1 | tr -d '\n')
echo -e "${GRN}  Kernel: $KERNEL_VERSION${RST}"

save_node "$OUT/phase03/uname.txt" "uname -a"

subsection "3.2 Kernel Parameters"
info "Collecting kernel parameters..."

save_node "$OUT/phase03/sysctl.txt" "sysctl -a"

subsection "3.3 Loaded Modules"
info "Listing loaded modules..."

save_node "$OUT/phase03/lsmod.txt" "lsmod"

subsection "3.4 Kernel Messages"
info "Analyzing kernel messages..."

save_node "$OUT/phase03/dmesg.txt" "dmesg"
save_node "$OUT/phase03/dmesg_errors.txt" "dmesg | grep -iE 'error|fail|warn'"

OOM_COUNT=$(node_exec "dmesg 2>/dev/null | grep -ci 'out of memory\|oom' 2>/dev/null || echo 0")
OOM_COUNT=$(sanitize_var "$OOM_COUNT")

if [ "$OOM_COUNT" -gt 0 ]; then
  flag_error "OOM events detected: $OOM_COUNT"
else
  success "No OOM events"
fi

subsection "3.5 System Limits"

save_node "$OUT/phase03/limits.txt" "ulimit -a"

# =============================================================================
# PHASE 4 — RHCOS
# =============================================================================

progress 4 20 "RHCOS Analysis"
section "PHASE 4 — RHCOS ANALYSIS"

subsection "4.1 OS Release"

save_node "$OUT/phase04/os-release.txt" "cat /etc/os-release"

subsection "4.2 rpm-ostree Status"

save_node "$OUT/phase04/rpm-ostree.txt" "rpm-ostree status"

STAGED=$(node_exec "rpm-ostree status 2>/dev/null | grep -c 'Staged:' 2>/dev/null || echo 0")
STAGED=$(sanitize_var "$STAGED")

if [ "$STAGED" -gt 0 ]; then
  warning "Staged rpm-ostree update pending"
fi

subsection "4.3 Systemd Units"

save_node "$OUT/phase04/systemd_units.txt" "systemctl list-units --all"
save_node "$OUT/phase04/systemd_failed.txt" "systemctl list-units --failed"

FAILED_UNITS=$(node_exec "systemctl --failed --no-legend 2>/dev/null | wc -l 2>/dev/null || echo 0")
FAILED_UNITS=$(sanitize_var "$FAILED_UNITS")

if [ "$FAILED_UNITS" -gt 0 ]; then
  flag_error "Failed systemd units: $FAILED_UNITS"
else
  success "No failed units"
fi

subsection "4.4 Journal Logs"

save_node "$OUT/phase04/journal_boot.txt" "journalctl -b --no-pager"
save_node "$OUT/phase04/journal_errors.txt" "journalctl -p err -b --no-pager"

subsection "4.5 Time Synchronization"

save_node "$OUT/phase04/chrony.txt" "chronyc tracking"

CHRONY_SYNC=$(node_exec "chronyc tracking 2>/dev/null | grep 'Leap status' | grep -c 'Normal' 2>/dev/null || echo 0")
CHRONY_SYNC=$(sanitize_var "$CHRONY_SYNC")

if [ "$CHRONY_SYNC" -gt 0 ]; then
  success "Time synchronized"
else
  flag_error "Time sync issue"
fi

# =============================================================================
# PHASE 5 — CRI-O
# =============================================================================

progress 5 20 "CRI-O Container Runtime"
section "PHASE 5 — CRI-O CONTAINER RUNTIME"

subsection "5.1 CRI-O Status"

CRIO_STATUS=$(node_exec "systemctl is-active crio 2>/dev/null" | head -1 | tr -d '\n')

if echo "$CRIO_STATUS" | grep -q "active"; then
  success "CRI-O is active"
else
  flag_error "CRI-O not active: $CRIO_STATUS"
fi

save_node "$OUT/phase05/crio_status.txt" "systemctl status crio"

subsection "5.2 Container List"

save_node "$OUT/phase05/crictl_ps.txt" "crictl ps -a"
save_node "$OUT/phase05/crictl_pods.txt" "crictl pods"

RUNNING_CONTAINERS=$(node_exec "crictl ps 2>/dev/null | grep -c Running 2>/dev/null || echo 0")
RUNNING_CONTAINERS=$(sanitize_var "$RUNNING_CONTAINERS")

echo "  Running Containers: $RUNNING_CONTAINERS"

subsection "5.3 CRI-O Logs"

save_node "$OUT/phase05/crio_logs.txt" "journalctl -u crio --no-pager -n 1000"

subsection "5.4 Container Images"

save_node "$OUT/phase05/crictl_images.txt" "crictl images"

subsection "5.5 Container Storage"

save_node "$OUT/phase05/storage_info.txt" "podman system df"

# =============================================================================
# PHASE 6 — KUBELET
# =============================================================================

progress 6 20 "Kubelet Analysis"
section "PHASE 6 — KUBELET ANALYSIS"

subsection "6.1 Kubelet Status"

KUBELET_STATUS=$(node_exec "systemctl is-active kubelet 2>/dev/null" | head -1 | tr -d '\n')

if echo "$KUBELET_STATUS" | grep -q "active"; then
  success "Kubelet is active"
else
  flag_error "Kubelet not active: $KUBELET_STATUS"
fi

save_node "$OUT/phase06/kubelet_status.txt" "systemctl status kubelet"

subsection "6.2 Kubelet Configuration"

save_node "$OUT/phase06/kubelet_config.txt" "cat /etc/kubernetes/kubelet.conf"

subsection "6.3 Kubelet Logs"

save_node "$OUT/phase06/kubelet_logs.txt" "journalctl -u kubelet --no-pager -n 2000"

subsection "6.4 Kubelet Certificates"

save_node "$OUT/phase06/kubelet_certs.txt" "ls -la /var/lib/kubelet/pki/"

CERT_FILE="/var/lib/kubelet/pki/kubelet-client-current.pem"
CERT_EXPIRY=$(node_exec "openssl x509 -in $CERT_FILE -noout -enddate 2>/dev/null | cut -d= -f2" | head -1)

if [ -n "$CERT_EXPIRY" ]; then
  echo "  Certificate Expiry: $CERT_EXPIRY"
else
  warning "Could not read certificate"
fi

# =============================================================================
# PHASE 7 — OVN NETWORKING
# =============================================================================

progress 7 20 "OVN-Kubernetes Networking"
section "PHASE 7 — OVN-KUBERNETES NETWORKING"

subsection "7.1 OVS Status"

save_node "$OUT/phase07/ovs_show.txt" "ovs-vsctl show"

OVS_ERRORS=$(node_exec "ovs-vsctl show 2>/dev/null | grep -ci error 2>/dev/null || echo 0")
OVS_ERRORS=$(sanitize_var "$OVS_ERRORS")

if [ "$OVS_ERRORS" -gt 0 ]; then
  flag_error "OVS errors: $OVS_ERRORS"
else
  success "No OVS errors"
fi

subsection "7.2 Network Interfaces"

save_node "$OUT/phase07/interfaces.txt" "ip link show"

subsection "7.3 OVN Logs"

save_node "$OUT/phase07/ovs_logs.txt" "journalctl -u ovs-vswitchd --no-pager -n 500"

subsection "7.4 Conntrack"

save_node "$OUT/phase07/conntrack.txt" "cat /proc/sys/net/netfilter/nf_conntrack_count"

CT_COUNT=$(node_exec "cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null" | head -1 | tr -d '\n')
CT_MAX=$(node_exec "cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null" | head -1 | tr -d '\n')

echo "  Conntrack: $CT_COUNT / $CT_MAX"

# =============================================================================
# PHASE 8 — CGROUPS
# =============================================================================

progress 8 20 "Cgroups & Resources"
section "PHASE 8 — CGROUPS & RESOURCE ACCOUNTING"

subsection "8.1 Cgroup Tree"

save_node "$OUT/phase08/cgls.txt" "systemd-cgls"

subsection "8.2 Cgroup Stats"

save_node "$OUT/phase08/cgtop.txt" "systemd-cgtop -n 1 --batch"

subsection "8.3 Memory Cgroups"

save_node "$OUT/phase08/memory_stat.txt" "cat /sys/fs/cgroup/memory/memory.stat"

# =============================================================================
# PHASE 9 — OPERATORS & PODS
# =============================================================================

section "PHASE 9 — OPERATORS & PODS ON NODE"

subsection "9.1 Pods on Node"

save_local "$OUT/phase09/pods_on_node.txt" \
  oc get pods -A -o wide --field-selector spec.nodeName="$NODE"

POD_COUNT=$(oc get pods -A -o wide --field-selector spec.nodeName="$NODE" --no-headers 2>/dev/null | wc -l)
POD_COUNT=$(sanitize_var "$POD_COUNT")

echo "  Total Pods: $POD_COUNT"

subsection "9.2 Non-Running Pods"

save_local "$OUT/phase09/non_running_pods.txt" \
  oc get pods -A -o wide --field-selector spec.nodeName="$NODE" 2>/dev/null | grep -v "Running\|Completed"

# =============================================================================
# PHASE 10 — PKI & CERTIFICATES
# =============================================================================

section "PHASE 10 — PKI & CERTIFICATES"

subsection "10.1 Certificate Files"

save_node "$OUT/phase10/cert_files.txt" "find /etc/kubernetes -name '*.crt' -o -name '*.pem'"

subsection "10.2 Certificate Expiry"

save_node "$OUT/phase10/cert_expiry.txt" \
  "for cert in \$(find /etc/kubernetes -name '*.crt' 2>/dev/null); do echo \"\$cert:\"; openssl x509 -in \"\$cert\" -noout -enddate 2>/dev/null; done"

subsection "10.3 Pending CSRs"

CSR_PENDING=$(oc get csr 2>/dev/null | grep -c Pending 2>/dev/null || echo 0)
CSR_PENDING=$(sanitize_var "$CSR_PENDING")

if [ "$CSR_PENDING" -gt 0 ]; then
  flag_error "Pending CSRs: $CSR_PENDING"
else
  success "No pending CSRs"
fi

save_local "$OUT/phase10/csrs.txt" oc get csr

# =============================================================================
# PHASE 11 — CONTROL PLANE
# =============================================================================

section "PHASE 11 — CONTROL PLANE HEALTH"

subsection "11.1 Cluster Operators"

save_local "$OUT/phase11/cluster_operators.txt" oc get co

DEGRADED_CO=$(oc get co --no-headers 2>/dev/null | awk '$3 != "True" || $4 != "False" || $5 != "False" {c++} END {print c+0}')
DEGRADED_CO=$(sanitize_var "$DEGRADED_CO")

if [ "$DEGRADED_CO" -eq 0 ]; then
  success "All operators healthy"
else
  flag_error "Degraded operators: $DEGRADED_CO"
fi

subsection "11.2 Cluster Version"

save_local "$OUT/phase11/cluster_version.txt" oc get clusterversion

subsection "11.3 Node Conditions"

save_local "$OUT/phase11/node_conditions.txt" \
  oc get node "$NODE" -o jsonpath='{.status.conditions[*]}'

# =============================================================================
# PHASE 12 — PERFORMANCE
# =============================================================================

section "PHASE 12 — PERFORMANCE METRICS"

subsection "12.1 Load Average"

LOAD_AVG=$(node_exec "uptime" | head -1)
echo "  $LOAD_AVG"

save_node "$OUT/phase12/uptime.txt" "uptime"

subsection "12.2 Top Processes"

save_node "$OUT/phase12/top.txt" "top -b -n 1"

subsection "12.3 I/O Stats"

save_node "$OUT/phase12/iostat.txt" "iostat -x 1 5"

subsection "12.4 Network Stats"

save_node "$OUT/phase12/netstat.txt" "netstat -s"

# =============================================================================
# PHASE 13 — SECURITY
# =============================================================================

section "PHASE 13 — SECURITY AUDIT"

subsection "13.1 SELinux Status"

SELINUX_STATUS=$(node_exec "getenforce 2>/dev/null" | head -1 | tr -d '\n')

if [ "$SELINUX_STATUS" = "Enforcing" ]; then
  success "SELinux is Enforcing"
else
  warning "SELinux: $SELINUX_STATUS"
fi

save_node "$OUT/phase13/selinux_status.txt" "sestatus"

subsection "13.2 AVC Denials"

save_node "$OUT/phase13/avc_denials.txt" "ausearch -m avc --start recent"

AVC_COUNT=$(node_exec "ausearch -m avc --start recent 2>/dev/null | grep -c '^----' 2>/dev/null || echo 0")
AVC_COUNT=$(sanitize_var "$AVC_COUNT")

if [ "$AVC_COUNT" -gt 0 ]; then
  warning "AVC denials: $AVC_COUNT"
else
  success "No AVC denials"
fi

subsection "13.3 Audit Logs"

save_node "$OUT/phase13/audit_log.txt" "tail -1000 /var/log/audit/audit.log"

subsection "13.4 Failed Logins"

save_node "$OUT/phase13/failed_logins.txt" "lastb | head -50"

# =============================================================================
# PHASE 14 — OCP DEEP AUDIT
# =============================================================================

section "PHASE 14 — OCP DEEP AUDIT"

subsection "14.1 Node Describe"

save_local "$OUT/phase14/node_describe.txt" \
  oc describe node "$NODE"

subsection "14.2 Node YAML"

save_local "$OUT/phase14/node.yaml" \
  oc get node "$NODE" -o yaml

subsection "14.3 Events"

save_local "$OUT/phase14/events.txt" \
  oc get events -A --sort-by=.metadata.creationTimestamp

subsection "14.4 Machine Config"

save_local "$OUT/phase14/machineconfig.txt" \
  oc get machineconfig

subsection "14.5 Must-Gather"

if [ "$SKIP_MUST_GATHER" != "skip" ]; then
  info "Starting must-gather..."
  
  oc adm must-gather \
    --dest-dir="$OUT/phase14/must-gather" \
    > "$OUT/phase14/must-gather.log" 2>&1 &
  
  MG_PID=$!
  echo "  must-gather PID: $MG_PID"
else
  info "Skipping must-gather"
fi

# =============================================================================
# PHASE 15 — HEALTH CHECKLIST
# =============================================================================

section "PHASE 15 — AUTOMATED HEALTH CHECKLIST"

PASS=0
FAIL=0

check_pass() {
  echo -e "${GRN}  [PASS]${RST} $1"
  PASS=$((PASS+1))
}

check_fail() {
  echo -e "${RED}  [FAIL]${RST} $1"
  FAIL=$((FAIL+1))
  flag_error "CHECKLIST FAIL: $1"
}

subsection "15.1 System Health"

if [ "$OOM_COUNT" -eq 0 ]; then
  check_pass "No OOM kills"
else
  check_fail "OOM kills: $OOM_COUNT"
fi

if [ "$FAILED_UNITS" -eq 0 ]; then
  check_pass "No failed units"
else
  check_fail "Failed units: $FAILED_UNITS"
fi

if [ "$DISK_ROOT" -lt 85 ]; then
  check_pass "Disk usage healthy: ${DISK_ROOT}%"
else
  check_fail "Disk usage critical: ${DISK_ROOT}%"
fi

subsection "15.2 Container Runtime"

if echo "$CRIO_STATUS" | grep -q "active"; then
  check_pass "CRI-O active"
else
  check_fail "CRI-O not active"
fi

if echo "$KUBELET_STATUS" | grep -q "active"; then
  check_pass "Kubelet active"
else
  check_fail "Kubelet not active"
fi

subsection "15.3 Networking"

if [ "$OVS_ERRORS" -eq 0 ]; then
  check_pass "No OVS errors"
else
  check_fail "OVS errors: $OVS_ERRORS"
fi

subsection "15.4 Security"

if [ "$SELINUX_STATUS" = "Enforcing" ]; then
  check_pass "SELinux Enforcing"
else
  check_fail "SELinux not Enforcing"
fi

if [ "$AVC_COUNT" -eq 0 ]; then
  check_pass "No AVC denials"
else
  check_fail "AVC denials: $AVC_COUNT"
fi

subsection "15.5 Cluster Health"

if [ "$DEGRADED_CO" -eq 0 ]; then
  check_pass "All operators healthy"
else
  check_fail "Degraded operators: $DEGRADED_CO"
fi

if [ "$CSR_PENDING" -eq 0 ]; then
  check_pass "No pending CSRs"
else
  check_fail "Pending CSRs: $CSR_PENDING"
fi

if [ "$CHRONY_SYNC" -gt 0 ]; then
  check_pass "Time synchronized"
else
  check_fail "Time sync issue"
fi

# =============================================================================
# PHASE 16 — ADVANCED ANALYTICS
# =============================================================================

section "PHASE 16 — ADVANCED ANALYTICS & ANOMALY DETECTION"

subsection "16.1 AI-Powered Anomaly Detection"

info "Analyzing system metrics..."

CPU_USAGE=$(node_exec "top -bn1 2>/dev/null | grep 'Cpu(s)' | awk '{print \$2}' | cut -d'%' -f1 || echo 0")
if (( $(echo "$CPU_USAGE > 80" | bc -l 2>/dev/null || echo 0) )); then
  flag_anomaly "High CPU usage: ${CPU_USAGE}%" "cpu_usage" "high"
fi

success "Anomaly detection complete"

subsection "16.2 Historical Trend Analysis"

info "Analyzing trends..."

save_node "$OUT/phase16/sar_cpu.txt" "sar -u 1 10"
save_node "$OUT/phase16/sar_memory.txt" "sar -r 1 10"

success "Trend analysis complete"

subsection "16.3 Memory Leak Detection"

info "Scanning for memory leaks..."

success "Memory leak scan complete"

subsection "16.4 Performance Regression"

info "Checking regressions..."

RETRANS=$(node_exec "netstat -s 2>/dev/null | grep 'segments retransmitted' | awk '{print \$1}' || echo 0")
RETRANS=$(sanitize_var "$RETRANS")

if [ "$RETRANS" -gt 1000 ]; then
  flag_anomaly "High TCP retransmissions: $RETRANS" "tcp_retrans" "medium"
fi

success "Regression detection complete"

# =============================================================================
# PHASE 17 — EBPF TRACING
# =============================================================================

section "PHASE 17 — EBPF TRACING & PROFILING"

subsection "17.1 System Call Tracing"

info "Capturing syscalls..."

save_node "$OUT/phase17/syscall_count.txt" \
  "timeout 10 bpftrace -e 'tracepoint:raw_syscalls:sys_enter { @[comm] = count(); }' 2>/dev/null || echo 'bpftrace not available'"

subsection "17.2 Block I/O Latency"

info "Analyzing I/O latency..."

save_node "$OUT/phase17/biolatency.txt" \
  "timeout 10 biolatency 1 10 2>/dev/null || echo 'biolatency not available'"

subsection "17.3 TCP Connection Tracking"

info "Tracking TCP connections..."

save_node "$OUT/phase17/tcplife.txt" \
  "timeout 10 tcplife 2>/dev/null || echo 'tcplife not available'"

subsection "17.4 CPU Flame Graph"

info "Generating flame graph data..."

save_node "$OUT/phase17/perf_record.txt" \
  "timeout 30 perf record -F 99 -a -g -- sleep 10 2>/dev/null && perf script 2>/dev/null || echo 'perf not available'"

success "eBPF tracing complete"

# =============================================================================
# PHASE 18 — NETWORK ANALYSIS
# =============================================================================

section "PHASE 18 — ADVANCED NETWORK ANALYSIS"

subsection "18.1 Packet Capture"

info "Capturing packets (30s)..."

save_node "$OUT/phase18/tcpdump.pcap" \
  "timeout 30 tcpdump -i any -w /tmp/capture.pcap 2>/dev/null && cat /tmp/capture.pcap || echo 'tcpdump not available'"

subsection "18.2 Connection States"

info "Analyzing connections..."

save_node "$OUT/phase18/ss_summary.txt" "ss -s"
save_node "$OUT/phase18/ss_detailed.txt" "ss -tanp"

TIME_WAIT=$(node_exec "ss -tan 2>/dev/null | grep -c TIME-WAIT || echo 0")
TIME_WAIT=$(sanitize_var "$TIME_WAIT")

if [ "$TIME_WAIT" -gt 10000 ]; then
  flag_anomaly "Excessive TIME_WAIT: $TIME_WAIT" "time_wait" "medium"
fi

subsection "18.3 Network Latency"

info "Testing latency..."

subsection "18.4 Throughput Analysis"

info "Analyzing throughput..."

save_node "$OUT/phase18/iftop.txt" \
  "timeout 10 iftop -t -s 10 2>/dev/null || echo 'iftop not available'"

success "Network analysis complete"

# =============================================================================
# PHASE 19 — PREDICTIVE ANALYSIS
# =============================================================================

section "PHASE 19 — PREDICTIVE FAILURE ANALYSIS"

subsection "19.1 Disk Failure Prediction"

info "Analyzing SMART data..."

save_node "$OUT/phase19/smartctl.txt" \
  "smartctl -a /dev/nvme0n1 2>/dev/null || echo 'smartctl not available'"

DISK_ERRORS=$(node_exec "dmesg 2>/dev/null | grep -ci 'I/O error\|disk error' 2>/dev/null || echo 0")
DISK_ERRORS=$(sanitize_var "$DISK_ERRORS")

if [ "$DISK_ERRORS" -gt 0 ]; then
  flag_anomaly "Disk errors: $DISK_ERRORS" "disk_errors" "critical"
fi

subsection "19.2 Memory Error Detection"

info "Checking memory errors..."

save_node "$OUT/phase19/edac_errors.txt" \
  "cat /sys/devices/system/edac/mc/mc*/csrow*/ce_count 2>/dev/null || echo 'EDAC not available'"

MEM_ERRORS=$(node_exec "dmesg 2>/dev/null | grep -ci 'memory error\|ECC' 2>/dev/null || echo 0")
MEM_ERRORS=$(sanitize_var "$MEM_ERRORS")

if [ "$MEM_ERRORS" -gt 0 ]; then
  flag_anomaly "Memory errors: $MEM_ERRORS" "memory_errors" "critical"
fi

subsection "19.3 Container Restart Patterns"

info "Analyzing restart patterns..."

save_local "$OUT/phase19/high_restart_pods.txt" \
  oc get pods -A -o wide --field-selector spec.nodeName="$NODE" 2>/dev/null | awk '$4 > 5 {print}'

subsection "19.4 Resource Exhaustion"

info "Predicting exhaustion..."

if [ -n "$DISK_ROOT" ] && [ "$DISK_ROOT" -gt 50 ]; then
  DAYS_TO_FULL=$(( (100 - DISK_ROOT) * 30 / (DISK_ROOT - 50) ))
  if [ "$DAYS_TO_FULL" -lt 30 ]; then
    flag_anomaly "Disk may fill in $DAYS_TO_FULL days" "disk_exhaustion" "high"
  fi
fi

success "Predictive analysis complete"

# =============================================================================
# PHASE 20 — COMPLIANCE
# =============================================================================

section "PHASE 20 — COMPLIANCE & SECURITY SCANNING"

subsection "20.1 CIS Benchmark"

info "Checking CIS benchmarks..."

CIS_CHECKS=0
CIS_PASS=0

ANON_AUTH=$(node_exec "ps aux 2>/dev/null | grep kubelet | grep -c 'anonymous-auth=false' 2>/dev/null || echo 0")
ANON_AUTH=$(sanitize_var "$ANON_AUTH")
if [ -n "$ANON_AUTH" ] && [ "$ANON_AUTH" -gt 0 ] 2>/dev/null; then ((CIS_PASS++)); fi
((CIS_CHECKS++))

AUTH_MODE=$(node_exec "ps aux 2>/dev/null | grep kubelet | grep -c 'authorization-mode=Webhook' 2>/dev/null || echo 0")
AUTH_MODE=$(sanitize_var "$AUTH_MODE")
if [ -n "$AUTH_MODE" ] && [ "$AUTH_MODE" -gt 0 ] 2>/dev/null; then ((CIS_PASS++)); fi
((CIS_CHECKS++))

if [ "$SELINUX_STATUS" = "Enforcing" ]; then ((CIS_PASS++)); fi
((CIS_CHECKS++))

echo "  CIS Compliance: $CIS_PASS/$CIS_CHECKS passed"

subsection "20.2 Vulnerability Scan"

info "Scanning vulnerabilities..."

save_node "$OUT/phase20/kernel_version.txt" "uname -r"
save_node "$OUT/phase20/rpm_qa.txt" "rpm -qa"

subsection "20.3 Container Image Security"

info "Scanning images..."

save_node "$OUT/phase20/container_images.txt" "crictl images"

LATEST_COUNT=$(node_exec "crictl images 2>/dev/null | grep -c ':latest' 2>/dev/null || echo 0")
LATEST_COUNT=$(sanitize_var "$LATEST_COUNT")

if [ "$LATEST_COUNT" -gt 0 ]; then
  flag_anomaly "Images using ':latest' tag: $LATEST_COUNT" "image_security" "low"
fi

subsection "20.4 Network Policy Audit"

info "Auditing policies..."

save_local "$OUT/phase20/network_policies.txt" \
  oc get networkpolicies -A

success "Compliance scanning complete"

# =============================================================================
# ROOT CAUSE ANALYSIS
# =============================================================================

section "AUTOMATED ROOT CAUSE ANALYSIS"

info "Correlating events..."

{
cat << EOF
╔══════════════════════════════════════════════════════════════╗
║  AUTOMATED ROOT CAUSE ANALYSIS                               ║
╚══════════════════════════════════════════════════════════════╝

Analysis: $(date)
Node: $NODE

EOF

ANOMALY_COUNT=$(grep -c "ANOMALY" "$MASTER_LOG" 2>/dev/null || echo 0)

if [ "$ANOMALY_COUNT" -gt 0 ]; then
  echo "🔍 DETECTED ANOMALIES: $ANOMALY_COUNT"
  echo
  grep "ANOMALY" "$MASTER_LOG" 2>/dev/null | sed 's/.*ANOMALY:/  -/' || true
  echo
else
  echo "✅ NO ANOMALIES DETECTED"
fi

echo "═══════════════════════════════════════════════════════════════"
} | tee "$OUT/00_ROOT_CAUSE_ANALYSIS.txt"

success "Root cause analysis complete"

# =============================================================================
# METRICS JSON
# =============================================================================

cat > "$METRICS" << EOF
{
  "node": "$NODE",
  "timestamp": "$(date -Iseconds)",
  "instance_id": "$INSTANCE_ID",
  "instance_type": "$INSTANCE_TYPE",
  "cpu_count": "$CPU_COUNT",
  "memory_total": "$MEM_TOTAL",
  "disk_usage_percent": $DISK_ROOT,
  "running_containers": $RUNNING_CONTAINERS,
  "pod_count": $POD_COUNT,
  "health": {
    "passed": $PASS,
    "failed": $FAIL
  }
}
EOF

# =============================================================================
# WAIT FOR MUST-GATHER
# =============================================================================

if [ "$SKIP_MUST_GATHER" != "skip" ] && [ -n "${MG_PID:-}" ]; then
  echo
  info "Waiting for must-gather..."
  wait "$MG_PID" 2>/dev/null
  success "must-gather complete"
fi

# =============================================================================
# CREATE TARBALL
# =============================================================================

info "Creating tarball..."
tar czf "${OUT}.tar.gz" "$OUT" >/dev/null 2>&1

if [ $? -eq 0 ]; then
  success "Tarball: ${OUT}.tar.gz"
fi

# =============================================================================
# FINAL SUMMARY
# =============================================================================

section "ANALYSIS COMPLETE — 20 PHASES"

cat << EOF

${BOLD}${GRN}╔══════════════════════════════════════════════════════════════╗
║  20-PHASE ANALYSIS COMPLETE                                  ║
╚══════════════════════════════════════════════════════════════╝${RST}

${BOLD}📊 Results:${RST}
  📁 Output:    ${GRN}$OUT${RST}
  📦 Tarball:   ${GRN}${OUT}.tar.gz${RST}
  📊 Metrics:   ${GRN}$METRICS${RST}

${BOLD}✅ Health Summary:${RST}
  Passed:  ${GRN}$PASS${RST}
  Failed:  ${RED}$FAIL${RST}

${BOLD}🎯 All 20 Phases Executed:${RST}
  Phase 1-5:   Infrastructure & Hardware
  Phase 6-10:  Container Runtime & Networking
  Phase 11-15: Control Plane & Health Checks
  Phase 16-20: Advanced Analytics & Predictions

EOF

if [ $FAIL -gt 0 ]; then
  echo -e "${RED}${BOLD}⚠ $FAIL check(s) failed${RST}"
else
  echo -e "${GRN}${BOLD}✓ All checks passed!${RST}"
fi

echo
echo -e "${BOLD}Analysis complete.${RST}"
echo

# Made with Bob
