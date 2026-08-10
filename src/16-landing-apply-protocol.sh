# ============================================================
# v5 受管落地秘密清单与 apply 协议（尚未接入远程执行）
# ============================================================

LANDING_CREDENTIAL_SCHEMA_VERSION=1
LANDING_APPLY_SCHEMA_VERSION=1
LANDING_RECEIPT_SCHEMA_VERSION=1
LANDING_APPLY_MAX_BYTES=1048576
LANDING_APPLY_MAX_TTL=600
LANDING_APPLY_CLOCK_SKEW=60
LANDING_RECEIPT_LOCK_TIMEOUT=30
LANDING_RECEIPT_FILE="${SB_LANDING_RECEIPT_FILE:-/var/lib/sb-user-manager/landing-receipt.json}"
LANDING_RECEIPT_LOCK_FILE="${SB_LANDING_RECEIPT_LOCK_FILE:-/run/lock/sb-user-manager/landing-receipt.lock}"

landing_id_is_valid() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{0,31}$ ]]
}

landing_safe_integer_is_valid() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  ((${#value} <= 16)) || return 1
  ((10#$value <= 9007199254740991))
}

landing_port_is_valid() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  ((${#value} <= 5)) || return 1
  ((10#$value >= 1 && 10#$value <= 65535))
}

landing_nonce_is_valid() {
  [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

landing_secret_material_path_is_valid() {
  local landing_id="$1" value="$2" filename="$3"
  [[ "$value" == "$CONTROLLER_SECRET_DIR/landing-${landing_id}/${filename}" ]]
}

validate_landing_credential_manifest_json() {
  local path="$1" landing_id gateway_server_name key value
  jq -e -s 'length == 1' "$path" >/dev/null || return 1
  jq -e --argjson schema "$LANDING_CREDENTIAL_SCHEMA_VERSION" '
    type == "object" and
    (keys | sort) == [
      "gateway_ca_certificate_file", "gateway_certificate_file", "gateway_password_file",
      "gateway_private_key_file", "gateway_server_name", "landing_id", "schema_version",
      "ssh_private_key_file"
    ] and
    .schema_version == $schema and
    (.landing_id | type == "string" and test("^[a-z][a-z0-9-]{0,31}$")) and
    (.gateway_server_name | type == "string" and length >= 3 and length <= 253) and
    all([
      .ssh_private_key_file, .gateway_password_file, .gateway_ca_certificate_file,
      .gateway_certificate_file, .gateway_private_key_file
    ][]; type == "string" and length >= 1)
  ' "$path" >/dev/null || return 1

  landing_id="$(jq -r '.landing_id' "$path")" || return 1
  gateway_server_name="$(jq -r '.gateway_server_name' "$path")" || return 1
  landing_id_is_valid "$landing_id" || return 1
  controller_dns_name_is_valid "$gateway_server_name" || return 1
  while IFS=$'\t' read -r key value; do
    case "$key" in
      ssh_private_key_file) landing_secret_material_path_is_valid "$landing_id" "$value" ssh-ed25519 || return 1 ;;
      gateway_password_file) landing_secret_material_path_is_valid "$landing_id" "$value" gateway-password || return 1 ;;
      gateway_ca_certificate_file) landing_secret_material_path_is_valid "$landing_id" "$value" gateway-ca.crt || return 1 ;;
      gateway_certificate_file) landing_secret_material_path_is_valid "$landing_id" "$value" gateway.crt || return 1 ;;
      gateway_private_key_file) landing_secret_material_path_is_valid "$landing_id" "$value" gateway.key || return 1 ;;
      *) return 1 ;;
    esac
  done < <(jq -r 'to_entries[] | select(.key | endswith("_file")) | [.key, .value] | @tsv' "$path")
}

controller_certificate_matches_sni() {
  local certificate="$1" server_name="$2"
  # 完整 SNI 只通过 stdin 交给 Python，不进入 python/openssl 的 argv。
  printf '%s' "$server_name" | python3 -I -c '
import ssl
import sys

name = sys.stdin.read().lower()
certificate = ssl._ssl._test_decode_cert(sys.argv[1])
dns_names = [
    value.lower()
    for kind, value in certificate.get("subjectAltName", ())
    if kind == "DNS"
]

def matches(pattern, hostname):
    if "*" not in pattern:
        return pattern == hostname
    if not pattern.startswith("*.") or pattern.count("*") != 1:
        return False
    return hostname.count(".") == pattern.count(".") and hostname.endswith(pattern[1:])

if not any(matches(pattern, name) for pattern in dns_names):
    raise SystemExit(1)
' "$certificate" >/dev/null 2>&1
}

controller_historical_certificate_attime() {
  python3 -I -c '
import calendar
import datetime
import ssl
import sys

fmt = "%b %d %H:%M:%S %Y %Z"

def bounds(path):
    cert = ssl._ssl._test_decode_cert(path)
    start = calendar.timegm(datetime.datetime.strptime(cert["notBefore"], fmt).timetuple())
    end = calendar.timegm(datetime.datetime.strptime(cert["notAfter"], fmt).timetuple())
    return start, end

ca_start, ca_end = bounds(sys.argv[1])
cert_start, cert_end = bounds(sys.argv[2])
start = max(ca_start, cert_start)
end = min(ca_end, cert_end)
if start >= end:
    raise SystemExit(1)
print(start + ((end - start) // 2))
' "$1" "$2"
}

validate_controller_tls_material() {
  local ca_certificate="$1" certificate="$2" private_key="$3" server_name="$4"
  local certificate_time_policy="${5:-current}"
  local certificate_public_sha private_public_sha historical_attime
  controller_state_file_is_trusted "$ca_certificate" || return 1
  controller_state_file_is_trusted "$certificate" || return 1
  controller_state_file_is_trusted "$private_key" || return 1
  controller_dns_name_is_valid "$server_name" || return 1
  [[ "$certificate_time_policy" == current || "$certificate_time_policy" == historical ]] || return 1
  [[ "$(grep -Fxc -- '-----BEGIN CERTIFICATE-----' "$ca_certificate" || true)" == 1 &&
     "$(grep -Fxc -- '-----END CERTIFICATE-----' "$ca_certificate" || true)" == 1 ]] || return 1
  [[ "$(grep -Fxc -- '-----BEGIN CERTIFICATE-----' "$certificate" || true)" == 1 &&
     "$(grep -Fxc -- '-----END CERTIFICATE-----' "$certificate" || true)" == 1 ]] || return 1
  [[ "$(grep -Ec '^-----BEGIN ([A-Z0-9]+ )?PRIVATE KEY-----$' "$private_key" || true)" == 1 &&
     "$(grep -Ec '^-----END ([A-Z0-9]+ )?PRIVATE KEY-----$' "$private_key" || true)" == 1 ]] || return 1
  openssl x509 -in "$ca_certificate" -noout >/dev/null 2>&1 || return 1
  if [[ "$certificate_time_policy" == current ]]; then
    openssl x509 -in "$certificate" -noout -checkend 3600 >/dev/null 2>&1 || return 1
    openssl verify -CAfile "$ca_certificate" "$certificate" >/dev/null 2>&1 || return 1
  else
    openssl x509 -in "$certificate" -noout >/dev/null 2>&1 || return 1
    historical_attime="$(controller_historical_certificate_attime "$ca_certificate" "$certificate")" || return 1
    [[ "$historical_attime" =~ ^[0-9]+$ ]] || return 1
    openssl verify -attime "$historical_attime" -CAfile "$ca_certificate" \
      "$certificate" >/dev/null 2>&1 || return 1
  fi
  certificate_public_sha="$(openssl x509 -in "$certificate" -pubkey -noout 2>/dev/null |
    sha256sum | awk '{print $1}')" || return 1
  private_public_sha="$(openssl pkey -in "$private_key" -passin pass: -pubout 2>/dev/null |
    sha256sum | awk '{print $1}')" || return 1
  [[ "$certificate_public_sha" =~ ^[0-9a-f]{64}$ &&
     "$certificate_public_sha" == "$private_public_sha" ]] || return 1
  controller_certificate_matches_sni "$certificate" "$server_name"
}

validate_landing_credential_manifest() {
  local path="$1" landing_id server_name ssh_key password_file ca_certificate certificate private_key
  local ssh_public_key
  controller_state_file_is_trusted "$path" || return 1
  validate_landing_credential_manifest_json "$path" || return 1
  landing_id="$(jq -r '.landing_id' "$path")" || return 1
  server_name="$(jq -r '.gateway_server_name' "$path")" || return 1
  controller_secret_ref_is_valid "$landing_id" "$path" || return 1
  controller_private_directory_is_trusted "$CONTROLLER_SECRET_DIR" || return 1
  controller_private_directory_is_trusted "$CONTROLLER_SECRET_DIR/landing-${landing_id}" || return 1
  ssh_key="$(jq -r '.ssh_private_key_file' "$path")" || return 1
  password_file="$(jq -r '.gateway_password_file' "$path")" || return 1
  ca_certificate="$(jq -r '.gateway_ca_certificate_file' "$path")" || return 1
  certificate="$(jq -r '.gateway_certificate_file' "$path")" || return 1
  private_key="$(jq -r '.gateway_private_key_file' "$path")" || return 1
  for path in "$ssh_key" "$password_file" "$ca_certificate" "$certificate" "$private_key"; do
    controller_state_file_is_trusted "$path" || return 1
  done
  ssh_public_key="$(ssh-keygen -y -P '' -f "$ssh_key" 2>/dev/null)" || return 1
  [[ "$ssh_public_key" == ssh-ed25519\ * ]] || return 1
  jq -e -Rs 'length >= 32 and length <= 128 and test("^[A-Za-z0-9_-]+$")' \
    "$password_file" >/dev/null || return 1
  validate_controller_tls_material "$ca_certificate" "$certificate" "$private_key" "$server_name"
}

landing_apply_content_sha256() {
  local package="$1"
  jq -cS '.gateway' "$package" | sha256sum | awk '{print $1}'
}

landing_apply_package_json_is_valid() {
  local package="$1" actual_sha expected_sha server_name allowed_entry_ipv4
  controller_state_file_is_trusted "$package" || return 1
  [[ "$(wc -c < "$package" | tr -d ' ')" -le "$LANDING_APPLY_MAX_BYTES" ]] || return 1
  jq -e -s 'length == 1' "$package" >/dev/null || return 1
  jq -e --argjson schema "$LANDING_APPLY_SCHEMA_VERSION" '
    type == "object" and
    (keys | sort) == [
      "content_sha256", "expires_at", "gateway", "issued_at", "landing_id",
      "nonce", "revision", "schema_version"
    ] and
    .schema_version == $schema and
    (.landing_id | type == "string" and test("^[a-z][a-z0-9-]{0,31}$")) and
    (.revision | type == "number" and . == floor and . >= 1 and . <= 9007199254740991) and
    (.issued_at | type == "number" and . == floor and . >= 0 and . <= 9007199254740991) and
    (.expires_at | type == "number" and . == floor and . >= 0 and . <= 9007199254740991) and
    (.nonce | type == "string" and test("^[0-9a-f]{64}$")) and
    (.content_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.gateway | type == "object") and
    (.gateway | keys | sort) == [
      "allowed_entry_ipv4", "ca_certificate_pem", "certificate_pem", "listen_port",
      "password", "private_key_pem", "server_name"
    ] and
    (.gateway.listen_port | type == "number" and . == floor and . >= 1 and . <= 65535) and
    (.gateway.server_name | type == "string" and length >= 3 and length <= 253) and
    (.gateway.password | type == "string" and length >= 32 and length <= 128 and
      test("^[A-Za-z0-9_-]+$")) and
    (.gateway.allowed_entry_ipv4 | type == "string" and length >= 7 and length <= 15) and
    (.gateway.ca_certificate_pem | type == "string" and
      startswith("-----BEGIN CERTIFICATE-----\n") and endswith("-----END CERTIFICATE-----\n")) and
    (.gateway.certificate_pem | type == "string" and
      startswith("-----BEGIN CERTIFICATE-----\n") and endswith("-----END CERTIFICATE-----\n")) and
    (.gateway.private_key_pem | type == "string" and
      startswith("-----BEGIN ") and endswith("PRIVATE KEY-----\n"))
  ' "$package" >/dev/null || return 1

  expected_sha="$(jq -r '.content_sha256' "$package")" || return 1
  actual_sha="$(landing_apply_content_sha256 "$package")" || return 1
  [[ "$actual_sha" == "$expected_sha" ]] || return 1
  server_name="$(jq -r '.gateway.server_name' "$package")" || return 1
  allowed_entry_ipv4="$(jq -r '.gateway.allowed_entry_ipv4' "$package")" || return 1
  controller_dns_name_is_valid "$server_name" || return 1
  is_ipv4_address "$allowed_entry_ipv4"
}

landing_apply_package_structure_is_valid() {
  local package="$1" certificate_time_policy="${2:-current}"
  local server_name work rc=0
  local validation_root="${SB_LANDING_APPLY_VALIDATION_ROOT:-}" persistent_validation=false
  [[ "$certificate_time_policy" == current || "$certificate_time_policy" == historical ]] || return 1
  landing_apply_package_json_is_valid "$package" || return 1
  server_name="$(jq -r '.gateway.server_name' "$package")" || return 1

  if [[ -n "$validation_root" ]]; then
    controller_private_directory_is_trusted "$validation_root" || return 1
    work="$validation_root/.validation"
    [[ ! -e "$work" && ! -L "$work" ]] || return 1
    install -d -m 700 -- "$work" || return 1
    controller_private_directory_is_trusted "$work" || return 1
    persistent_validation=true
  else
    work="$(mktemp -d /tmp/sb-landing-apply-validate.XXXXXX)" || return 1
    register_temp_path "$work" || { rm -rf -- "$work"; return 1; }
  fi
  if ! jq -r '.gateway.ca_certificate_pem' "$package" > "$work/ca.crt" ||
     ! jq -r '.gateway.certificate_pem' "$package" > "$work/gateway.crt" ||
     ! jq -r '.gateway.private_key_pem' "$package" > "$work/gateway.key" ||
     ! chmod 600 "$work/ca.crt" "$work/gateway.crt" "$work/gateway.key" ||
     ! validate_controller_tls_material \
       "$work/ca.crt" "$work/gateway.crt" "$work/gateway.key" "$server_name" \
       "$certificate_time_policy"; then
    rc=1
  fi
  rm -rf -- "$work" || rc=1
  if [[ "$persistent_validation" == true ]]; then
    sync_transaction_path "$validation_root" || rc=1
  fi
  return "$rc"
}

landing_apply_package_is_fresh() {
  local package="$1" now="${2:-$(date +%s)}" issued_at expires_at
  landing_safe_integer_is_valid "$now" || return 1
  issued_at="$(jq -r '.issued_at' "$package")" || return 1
  expires_at="$(jq -r '.expires_at' "$package")" || return 1
  landing_safe_integer_is_valid "$issued_at" || return 1
  landing_safe_integer_is_valid "$expires_at" || return 1
  ((expires_at > issued_at && expires_at - issued_at <= LANDING_APPLY_MAX_TTL)) || return 1
  ((issued_at <= now + LANDING_APPLY_CLOCK_SKEW && expires_at > now))
}

validate_landing_apply_package() {
  local package="$1" now="${2:-$(date +%s)}"
  landing_apply_package_structure_is_valid "$package" || return 1
  landing_apply_package_is_fresh "$package" "$now"
}

build_landing_apply_package() {
  local manifest="$1" allowed_entry_ipv4="$2" gateway_port="$3" revision="$4"
  local issued_at="$5" expires_at="$6" nonce="$7" output="$8"
  local output_dir openssl_path helper_rc=0 test_stop_stage='' test_unsupported_stage=''
  local test_expected_link_method='' test_forced_link_method='' test_diagnostics=''
  validate_landing_credential_manifest "$manifest" || return 1
  is_ipv4_address "$allowed_entry_ipv4" || return 1
  landing_port_is_valid "$gateway_port" || return 1
  landing_safe_integer_is_valid "$revision" || return 1
  ((10#$revision >= 1)) || return 1
  landing_safe_integer_is_valid "$issued_at" || return 1
  landing_safe_integer_is_valid "$expires_at" || return 1
  landing_nonce_is_valid "$nonce" || return 1
  [[ ! -e "$output" && ! -L "$output" ]] || return 1
  output_dir="$(dirname "$output")"
  controller_private_directory_is_trusted "$output_dir" || return 1
  openssl_path="$(type -P openssl)" || return 1
  [[ "$openssl_path" == /* && -x "$openssl_path" ]] || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
    test_stop_stage="${SB_LANDING_APPLY_TEST_STOP_STAGE:-}"
    test_unsupported_stage="${SB_LANDING_APPLY_TEST_FORCE_UNSUPPORTED_AT:-}"
    test_expected_link_method="${SB_LANDING_APPLY_TEST_EXPECT_LINK_METHOD:-}"
    test_forced_link_method="${SB_LANDING_APPLY_TEST_FORCE_LINK_METHOD:-}"
    test_diagnostics="${SB_LANDING_APPLY_TEST_DIAGNOSTICS:-}"
  fi

  if SB_LANDING_APPLY_MANIFEST_PATH="$manifest" \
    SB_LANDING_APPLY_OUTPUT_PATH="$output" \
    SB_LANDING_CONTROLLER_SECRET_DIR="$CONTROLLER_SECRET_DIR" \
    SB_LANDING_CREDENTIAL_SCHEMA_VERSION="$LANDING_CREDENTIAL_SCHEMA_VERSION" \
    SB_LANDING_OPENSSL_PATH="$openssl_path" \
    SB_LANDING_ALLOWED_ENTRY_IPV4="$allowed_entry_ipv4" \
    SB_LANDING_GATEWAY_PORT="$gateway_port" \
    SB_LANDING_APPLY_REVISION="$revision" \
    SB_LANDING_APPLY_ISSUED_AT="$issued_at" \
    SB_LANDING_APPLY_EXPIRES_AT="$expires_at" \
    SB_LANDING_APPLY_NONCE="$nonce" \
    SB_LANDING_APPLY_SCHEMA_VERSION="$LANDING_APPLY_SCHEMA_VERSION" \
    SB_LANDING_APPLY_MAX_BYTES="$LANDING_APPLY_MAX_BYTES" \
    SB_LANDING_APPLY_MAX_TTL="$LANDING_APPLY_MAX_TTL" \
    SB_LANDING_APPLY_CLOCK_SKEW="$LANDING_APPLY_CLOCK_SKEW" \
    SB_LANDING_APPLY_PARENT_PID="${BASHPID:-$$}" \
    SB_LANDING_APPLY_TEST_STOP_STAGE="$test_stop_stage" \
    SB_LANDING_APPLY_TEST_FORCE_UNSUPPORTED_AT="$test_unsupported_stage" \
    SB_LANDING_APPLY_TEST_EXPECT_LINK_METHOD="$test_expected_link_method" \
    SB_LANDING_APPLY_TEST_FORCE_LINK_METHOD="$test_forced_link_method" \
    SB_LANDING_APPLY_TEST_DIAGNOSTICS="$test_diagnostics" \
    python3 -I - <<'PY'
import ctypes
import errno
import hashlib
import hmac
import json
import os
import re
import resource
import signal
import ssl
import stat
import subprocess
import sys

UNSUPPORTED_STATUS = 73
PR_SET_PDEATHSIG = 1
PR_SET_DUMPABLE = 4
AT_FDCWD = -100
AT_SYMLINK_FOLLOW = 0x400
AT_EMPTY_PATH = 0x1000
SAFE_INTEGER_MAX = 9007199254740991


class BuildFailure(Exception):
    pass


class AnonymousPublishingUnsupported(BuildFailure):
    pass


def require(condition):
    if not condition:
        raise BuildFailure()


def emit_test_diagnostic(error):
    if os.environ.get("SB_LANDING_APPLY_TEST_DIAGNOSTICS") != "true":
        return
    kind = type(error).__name__
    if re.fullmatch(r"[A-Za-z]+", kind) is None:
        kind = "Exception"
    lines = []
    trace = error.__traceback__
    while trace is not None and len(lines) < 16:
        lines.append(str(trace.tb_lineno))
        trace = trace.tb_next
    payload = f"landing apply helper test diagnostic: {kind}:{','.join(lines)}\n"
    try:
        os.write(2, payload.encode("ascii", "strict"))
    except BaseException:
        pass


def env(name, maximum=4096):
    value = os.environ.get(name)
    require(value is not None and 0 < len(value) <= maximum)
    return value


def env_integer(name, maximum, digits):
    value = env(name, digits)
    require(re.fullmatch(r"[0-9]+", value) is not None)
    number = int(value, 10)
    require(number <= maximum)
    return number


def arm_process_safety(expected_parent):
    if not sys.platform.startswith("linux") or not hasattr(os, "O_TMPFILE"):
        raise AnonymousPublishingUnsupported()
    os.umask(0o077)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    try:
        with open("/proc/self/coredump_filter", "w", encoding="ascii") as core_filter:
            core_filter.write("0\n")
    except OSError:
        raise AnonymousPublishingUnsupported() from None
    require(os.getppid() == expected_parent)
    libc = ctypes.CDLL(None, use_errno=True)
    require(libc.prctl(PR_SET_PDEATHSIG, signal.SIGKILL, 0, 0, 0) == 0)
    require(os.getppid() == expected_parent)
    require(libc.prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) == 0)
    return libc


def read_private_text(path, maximum):
    flags = os.O_RDONLY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        metadata = os.fstat(descriptor)
        require(stat.S_ISREG(metadata.st_mode))
        require(metadata.st_uid == os.geteuid())
        require(stat.S_IMODE(metadata.st_mode) == 0o600)
        require(0 <= metadata.st_size <= maximum)
        chunks = []
        remaining = maximum + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        require(len(data) <= maximum)
        return data.decode("utf-8", "strict")
    finally:
        os.close(descriptor)


def valid_dns_name(value):
    if not 3 <= len(value) <= 253:
        return False
    if "." not in value or value.startswith(".") or value.endswith(".") or ".." in value:
        return False
    if re.fullmatch(r"[A-Za-z0-9.-]+", value) is None:
        return False
    for label in value.split("."):
        if not 1 <= len(label) <= 63:
            return False
        if re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?", label) is None:
            return False
    return True


def valid_ipv4(value):
    if not 7 <= len(value) <= 15:
        return False
    parts = value.split(".")
    return len(parts) == 4 and all(part.isascii() and part.isdigit() and int(part, 10) <= 255 for part in parts)


def checkpoint(name, selected):
    if selected == name:
        os.kill(os.getpid(), signal.SIGSTOP)


def write_all(descriptor, payload):
    position = 0
    while position < len(payload):
        written = os.write(descriptor, payload[position:])
        require(written > 0)
        position += written


def read_all(descriptor, maximum):
    os.lseek(descriptor, 0, os.SEEK_SET)
    chunks = []
    remaining = maximum + 1
    while remaining > 0:
        chunk = os.read(descriptor, min(65536, remaining))
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    payload = b"".join(chunks)
    require(0 < len(payload) <= maximum)
    return payload


def safe_fsync(descriptor):
    try:
        os.fsync(descriptor)
    except OSError as error:
        if error.errno in {
            errno.EACCES, errno.EINVAL, errno.ENOSYS, errno.ENOTSUP,
            errno.EOPNOTSUPP, errno.EPERM, errno.EROFS
        }:
            raise AnonymousPublishingUnsupported() from None
        raise BuildFailure() from None


def create_secret_memfd(label, payload):
    if not hasattr(os, "memfd_create"):
        raise AnonymousPublishingUnsupported()
    flags = getattr(os, "MFD_CLOEXEC", 0x0001)
    try:
        descriptor = os.memfd_create(f"sb-landing-{label}", flags)
    except OSError as error:
        if error.errno in {
            errno.EACCES, errno.EINVAL, errno.ENOSYS, errno.ENOTSUP,
            errno.EOPNOTSUPP, errno.EPERM
        }:
            raise AnonymousPublishingUnsupported() from None
        raise BuildFailure() from None
    try:
        encoded_payload = payload.encode("utf-8")
        os.fchmod(descriptor, 0o600)
        write_all(descriptor, encoded_payload)
        os.lseek(descriptor, 0, os.SEEK_SET)
        metadata = os.fstat(descriptor)
        require(stat.S_ISREG(metadata.st_mode))
        require(metadata.st_uid == os.geteuid())
        require(stat.S_IMODE(metadata.st_mode) == 0o600)
        require(metadata.st_nlink == 0)
        require(metadata.st_size == len(encoded_payload))
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def run_openssl(libc, openssl_path, arguments, inherited_fds, capture=False):
    python_pid = os.getpid()
    for descriptor in inherited_fds:
        os.lseek(descriptor, 0, os.SEEK_SET)

    def arm_child_parent_death():
        if libc.prctl(PR_SET_PDEATHSIG, signal.SIGKILL, 0, 0, 0) != 0:
            os._exit(127)
        if os.getppid() != python_pid:
            os._exit(127)

    result = subprocess.run(
        [openssl_path, *arguments],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=True,
        pass_fds=tuple(inherited_fds),
        env={"LANG": "C", "LC_ALL": "C"},
        timeout=10,
        check=False,
        preexec_fn=arm_child_parent_death,
    )
    require(result.returncode == 0)
    if capture:
        require(result.stdout is not None and len(result.stdout) <= 65536)
        return result.stdout
    return b""


def validate_tls_snapshot(libc, openssl_path, ca_certificate, certificate, private_key,
                          server_name, stop_stage):
    require(ca_certificate.count("-----BEGIN CERTIFICATE-----\n") == 1)
    require(ca_certificate.count("-----END CERTIFICATE-----\n") == 1)
    require(certificate.count("-----BEGIN CERTIFICATE-----\n") == 1)
    require(certificate.count("-----END CERTIFICATE-----\n") == 1)
    require(len(re.findall(r"(?m)^-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY-----$", private_key)) == 1)
    require(len(re.findall(r"(?m)^-----END (?:[A-Z0-9]+ )?PRIVATE KEY-----$", private_key)) == 1)
    if not os.path.isdir("/proc/self/fd"):
        raise AnonymousPublishingUnsupported()
    descriptors = []
    try:
        descriptors.append(create_secret_memfd("ca", ca_certificate))
        descriptors.append(create_secret_memfd("certificate", certificate))
        descriptors.append(create_secret_memfd("private-key", private_key))
        checkpoint("validation_material_ready", stop_stage)
        ca_path, certificate_path, private_key_path = (
            f"/proc/self/fd/{descriptor}" for descriptor in descriptors
        )
        run_openssl(libc, openssl_path, ["x509", "-in", ca_path, "-noout"], descriptors)
        run_openssl(
            libc, openssl_path,
            ["x509", "-in", certificate_path, "-noout", "-checkend", "3600"],
            descriptors,
        )
        run_openssl(
            libc, openssl_path, ["verify", "-CAfile", ca_path, certificate_path], descriptors
        )
        certificate_public = run_openssl(
            libc, openssl_path, ["x509", "-in", certificate_path, "-pubkey", "-noout"],
            descriptors, capture=True
        )
        private_public = run_openssl(
            libc, openssl_path,
            ["pkey", "-in", private_key_path, "-passin", "pass:", "-pubout"],
            descriptors, capture=True
        )
        require(hmac.compare_digest(
            hashlib.sha256(certificate_public).digest(), hashlib.sha256(private_public).digest()
        ))
        os.lseek(descriptors[1], 0, os.SEEK_SET)
        decoded = ssl._ssl._test_decode_cert(certificate_path)
        dns_names = [
            value.lower()
            for kind, value in decoded.get("subjectAltName", ())
            if kind == "DNS"
        ]

        def matches(pattern, hostname):
            if "*" not in pattern:
                return pattern == hostname
            if not pattern.startswith("*.") or pattern.count("*") != 1:
                return False
            return hostname.count(".") == pattern.count(".") and hostname.endswith(pattern[1:])

        require(any(matches(pattern, server_name.lower()) for pattern in dns_names))
    finally:
        for descriptor in descriptors:
            os.close(descriptor)


def validate_package(payload, expected_gateway, expected_landing_id, schema, revision,
                     issued_at, expires_at, nonce, maximum_bytes, maximum_ttl, clock_skew):
    require(0 < len(payload) <= maximum_bytes)
    package = json.loads(payload.decode("utf-8", "strict"))
    require(type(package) is dict)
    require(set(package) == {
        "schema_version", "landing_id", "revision", "issued_at", "expires_at",
        "nonce", "content_sha256", "gateway"
    })
    require(type(package.get("schema_version")) is int and package["schema_version"] == schema)
    landing_id = package.get("landing_id")
    require(type(landing_id) is str and re.fullmatch(r"[a-z][a-z0-9-]{0,31}", landing_id) is not None)
    require(landing_id == expected_landing_id)
    for key, expected in (("revision", revision), ("issued_at", issued_at), ("expires_at", expires_at)):
        require(type(package.get(key)) is int and 0 <= package[key] <= SAFE_INTEGER_MAX)
        require(package[key] == expected)
    require(package["revision"] >= 1)
    require(expires_at > issued_at and expires_at - issued_at <= maximum_ttl)
    require(issued_at <= issued_at + clock_skew and expires_at > issued_at)
    require(type(package.get("nonce")) is str and re.fullmatch(r"[0-9a-f]{64}", package["nonce"]) is not None)
    require(package["nonce"] == nonce)
    require(type(package.get("content_sha256")) is str and
            re.fullmatch(r"[0-9a-f]{64}", package["content_sha256"]) is not None)
    gateway = package.get("gateway")
    require(type(gateway) is dict and gateway == expected_gateway)
    require(set(gateway) == {
        "listen_port", "server_name", "password", "allowed_entry_ipv4",
        "ca_certificate_pem", "certificate_pem", "private_key_pem"
    })
    require(type(gateway["listen_port"]) is int and 1 <= gateway["listen_port"] <= 65535)
    require(type(gateway["server_name"]) is str and valid_dns_name(gateway["server_name"]))
    # Keep jq's existing `test("^[A-Za-z0-9_-]+$")` semantics exactly: its `$`
    # also matches immediately before one trailing newline. Tightening that legacy
    # input rule belongs in a schema/validator change, not in this publisher.
    require(type(gateway["password"]) is str and 32 <= len(gateway["password"]) <= 128 and
            re.match(r"^[A-Za-z0-9_-]+$", gateway["password"]) is not None)
    require(type(gateway["allowed_entry_ipv4"]) is str and valid_ipv4(gateway["allowed_entry_ipv4"]))
    require(type(gateway["ca_certificate_pem"]) is str and
            gateway["ca_certificate_pem"].startswith("-----BEGIN CERTIFICATE-----\n") and
            gateway["ca_certificate_pem"].endswith("-----END CERTIFICATE-----\n"))
    require(type(gateway["certificate_pem"]) is str and
            gateway["certificate_pem"].startswith("-----BEGIN CERTIFICATE-----\n") and
            gateway["certificate_pem"].endswith("-----END CERTIFICATE-----\n"))
    require(type(gateway["private_key_pem"]) is str and
            gateway["private_key_pem"].startswith("-----BEGIN ") and
            gateway["private_key_pem"].endswith("PRIVATE KEY-----\n"))
    canonical_gateway = json.dumps(
        gateway, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8") + b"\n"
    require(hashlib.sha256(canonical_gateway).hexdigest() == package["content_sha256"])


def anonymous_open(directory_fd):
    flags = os.O_RDWR | os.O_CLOEXEC | os.O_TMPFILE
    try:
        return os.open(".", flags, 0o600, dir_fd=directory_fd)
    except OSError as error:
        if error.errno in {
            errno.EACCES, errno.EINVAL, errno.EISDIR, errno.ENOSYS, errno.ENOTSUP,
            errno.EOPNOTSUPP, errno.EPERM
        }:
            raise AnonymousPublishingUnsupported() from None
        raise BuildFailure() from None


def link_anonymous(libc, anonymous_fd, directory_fd, basename, forced_method):
    linkat = libc.linkat
    linkat.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
    linkat.restype = ctypes.c_int
    encoded_name = os.fsencode(basename)
    if forced_method != "proc":
        if linkat(anonymous_fd, b"", directory_fd, encoded_name, AT_EMPTY_PATH) == 0:
            return "direct"
        direct_errno = ctypes.get_errno()
        if direct_errno == errno.EEXIST:
            raise BuildFailure()
        if direct_errno not in {
            errno.EACCES, errno.ENOENT, errno.EINVAL, errno.ENOSYS, errno.ENOTSUP,
            errno.EOPNOTSUPP, errno.EPERM
        }:
            raise BuildFailure()
    proc_path = os.fsencode(f"/proc/self/fd/{anonymous_fd}")
    if linkat(AT_FDCWD, proc_path, directory_fd, encoded_name, AT_SYMLINK_FOLLOW) == 0:
        return "proc"
    proc_errno = ctypes.get_errno()
    if proc_errno == errno.EEXIST:
        raise BuildFailure()
    if proc_errno in {
        errno.EACCES, errno.ENOENT, errno.EINVAL, errno.ENOSYS, errno.ENOTSUP,
        errno.EOPNOTSUPP, errno.EPERM, errno.EXDEV
    }:
        raise AnonymousPublishingUnsupported()
    raise BuildFailure()


def unlink_published_if_owned(directory_fd, basename, anonymous_metadata):
    try:
        target_metadata = os.stat(basename, dir_fd=directory_fd, follow_symlinks=False)
        if (target_metadata.st_dev, target_metadata.st_ino) == (
            anonymous_metadata.st_dev, anonymous_metadata.st_ino
        ):
            os.unlink(basename, dir_fd=directory_fd)
            os.fsync(directory_fd)
    except OSError:
        pass


def main():
    expected_parent = env_integer("SB_LANDING_APPLY_PARENT_PID", SAFE_INTEGER_MAX, 16)
    libc = arm_process_safety(expected_parent)
    manifest_path = env("SB_LANDING_APPLY_MANIFEST_PATH")
    output_path = env("SB_LANDING_APPLY_OUTPUT_PATH")
    controller_secret_dir = env("SB_LANDING_CONTROLLER_SECRET_DIR")
    credential_schema = env_integer("SB_LANDING_CREDENTIAL_SCHEMA_VERSION", SAFE_INTEGER_MAX, 16)
    openssl_path = env("SB_LANDING_OPENSSL_PATH")
    require(os.path.isabs(openssl_path) and os.access(openssl_path, os.X_OK))
    openssl_metadata = os.stat(openssl_path, follow_symlinks=True)
    require(stat.S_ISREG(openssl_metadata.st_mode) and openssl_metadata.st_uid == 0)
    allowed_entry_ipv4 = env("SB_LANDING_ALLOWED_ENTRY_IPV4", 15)
    gateway_port = env_integer("SB_LANDING_GATEWAY_PORT", 65535, 5)
    revision = env_integer("SB_LANDING_APPLY_REVISION", SAFE_INTEGER_MAX, 16)
    issued_at = env_integer("SB_LANDING_APPLY_ISSUED_AT", SAFE_INTEGER_MAX, 16)
    expires_at = env_integer("SB_LANDING_APPLY_EXPIRES_AT", SAFE_INTEGER_MAX, 16)
    nonce = env("SB_LANDING_APPLY_NONCE", 64)
    schema = env_integer("SB_LANDING_APPLY_SCHEMA_VERSION", SAFE_INTEGER_MAX, 16)
    maximum_bytes = env_integer("SB_LANDING_APPLY_MAX_BYTES", SAFE_INTEGER_MAX, 16)
    maximum_ttl = env_integer("SB_LANDING_APPLY_MAX_TTL", SAFE_INTEGER_MAX, 16)
    clock_skew = env_integer("SB_LANDING_APPLY_CLOCK_SKEW", SAFE_INTEGER_MAX, 16)
    stop_stage = os.environ.get("SB_LANDING_APPLY_TEST_STOP_STAGE", "")
    unsupported_stage = os.environ.get("SB_LANDING_APPLY_TEST_FORCE_UNSUPPORTED_AT", "")
    expected_link_method = os.environ.get("SB_LANDING_APPLY_TEST_EXPECT_LINK_METHOD", "")
    forced_link_method = os.environ.get("SB_LANDING_APPLY_TEST_FORCE_LINK_METHOD", "")
    require(stop_stage in {
        "", "before_secret_read", "sources_read", "gateway_assembled",
        "package_write_started", "package_written", "before_validation",
        "validation_material_ready", "after_validation", "after_file_sync",
        "before_publish", "after_publish", "after_directory_sync"
    })
    require(unsupported_stage in {
        "", "anonymous_open", "directory_fsync", "file_fsync", "link"
    })
    require(expected_link_method in {"", "direct", "proc"})
    require(forced_link_method in {"", "proc"})

    manifest_text = read_private_text(manifest_path, maximum_bytes)
    manifest = json.loads(manifest_text)
    require(type(manifest) is dict and set(manifest) == {
        "schema_version", "landing_id", "gateway_server_name", "ssh_private_key_file",
        "gateway_password_file", "gateway_ca_certificate_file",
        "gateway_certificate_file", "gateway_private_key_file"
    })
    landing_id = manifest.get("landing_id")
    server_name = manifest.get("gateway_server_name")
    require(type(manifest.get("schema_version")) is int and
            manifest["schema_version"] == credential_schema)
    require(type(landing_id) is str and re.fullmatch(r"[a-z][a-z0-9-]{0,31}", landing_id) is not None)
    require(type(server_name) is str and valid_dns_name(server_name))
    require(manifest_path == os.path.join(controller_secret_dir, f"landing-{landing_id}.json"))
    expected_secret_directory = os.path.join(controller_secret_dir, f"landing-{landing_id}")
    expected_secret_paths = {
        "ssh_private_key_file": os.path.join(expected_secret_directory, "ssh-ed25519"),
        "gateway_password_file": os.path.join(expected_secret_directory, "gateway-password"),
        "gateway_ca_certificate_file": os.path.join(expected_secret_directory, "gateway-ca.crt"),
        "gateway_certificate_file": os.path.join(expected_secret_directory, "gateway.crt"),
        "gateway_private_key_file": os.path.join(expected_secret_directory, "gateway.key"),
    }
    require(all(type(manifest.get(name)) is str and manifest[name] == expected
                for name, expected in expected_secret_paths.items()))
    checkpoint("before_secret_read", stop_stage)
    password = read_private_text(manifest["gateway_password_file"], 512)
    ca_certificate = read_private_text(manifest["gateway_ca_certificate_file"], maximum_bytes)
    certificate = read_private_text(manifest["gateway_certificate_file"], maximum_bytes)
    private_key = read_private_text(manifest["gateway_private_key_file"], maximum_bytes)
    checkpoint("sources_read", stop_stage)

    gateway = {
        "listen_port": gateway_port,
        "server_name": server_name,
        "password": password,
        "allowed_entry_ipv4": allowed_entry_ipv4,
        "ca_certificate_pem": ca_certificate,
        "certificate_pem": certificate,
        "private_key_pem": private_key,
    }
    checkpoint("gateway_assembled", stop_stage)
    canonical_gateway = json.dumps(
        gateway, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8") + b"\n"
    digest = hashlib.sha256(canonical_gateway).hexdigest()
    package = {
        "schema_version": schema,
        "landing_id": landing_id,
        "revision": revision,
        "issued_at": issued_at,
        "expires_at": expires_at,
        "nonce": nonce,
        "content_sha256": digest,
        "gateway": gateway,
    }
    payload = json.dumps(package, ensure_ascii=False, indent=2).encode("utf-8") + b"\n"
    require(0 < len(payload) <= maximum_bytes)

    output_directory = os.path.dirname(output_path) or "."
    basename = os.path.basename(output_path)
    require(basename not in {"", ".", ".."} and "/" not in basename)
    directory_flags = os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        directory_flags |= os.O_NOFOLLOW
    directory_fd = os.open(output_directory, directory_flags)
    anonymous_fd = -1
    published = False
    anonymous_metadata = None
    try:
        directory_metadata = os.fstat(directory_fd)
        require(stat.S_ISDIR(directory_metadata.st_mode))
        require(directory_metadata.st_uid == os.geteuid())
        require(stat.S_IMODE(directory_metadata.st_mode) == 0o700)
        try:
            os.stat(basename, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise BuildFailure()
        if unsupported_stage == "directory_fsync":
            raise AnonymousPublishingUnsupported()
        safe_fsync(directory_fd)
        if unsupported_stage == "anonymous_open":
            raise AnonymousPublishingUnsupported()
        anonymous_fd = anonymous_open(directory_fd)
        os.fchmod(anonymous_fd, 0o600)
        anonymous_metadata = os.fstat(anonymous_fd)
        require(stat.S_ISREG(anonymous_metadata.st_mode))
        require(anonymous_metadata.st_uid == os.geteuid())
        require(stat.S_IMODE(anonymous_metadata.st_mode) == 0o600)
        require(anonymous_metadata.st_nlink == 0)
        midpoint = max(1, len(payload) // 2)
        write_all(anonymous_fd, payload[:midpoint])
        checkpoint("package_write_started", stop_stage)
        write_all(anonymous_fd, payload[midpoint:])
        checkpoint("package_written", stop_stage)
        checkpoint("before_validation", stop_stage)
        stored_payload = read_all(anonymous_fd, maximum_bytes)
        require(stored_payload == payload)
        validate_tls_snapshot(
            libc, openssl_path, ca_certificate, certificate, private_key,
            server_name, stop_stage
        )
        validate_package(
            stored_payload, gateway, landing_id, schema, revision, issued_at, expires_at,
            nonce, maximum_bytes, maximum_ttl, clock_skew
        )
        checkpoint("after_validation", stop_stage)
        if unsupported_stage == "file_fsync":
            raise AnonymousPublishingUnsupported()
        safe_fsync(anonymous_fd)
        checkpoint("after_file_sync", stop_stage)
        anonymous_metadata = os.fstat(anonymous_fd)
        require(anonymous_metadata.st_nlink == 0)
        require(anonymous_metadata.st_size == len(payload))
        try:
            os.stat(basename, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise BuildFailure()
        checkpoint("before_publish", stop_stage)
        if unsupported_stage == "link":
            raise AnonymousPublishingUnsupported()
        link_method = link_anonymous(
            libc, anonymous_fd, directory_fd, basename, forced_link_method
        )
        published = True
        require(not expected_link_method or link_method == expected_link_method)
        checkpoint("after_publish", stop_stage)
        target_metadata = os.stat(basename, dir_fd=directory_fd, follow_symlinks=False)
        require(stat.S_ISREG(target_metadata.st_mode))
        require(target_metadata.st_uid == os.geteuid())
        require(stat.S_IMODE(target_metadata.st_mode) == 0o600)
        require(target_metadata.st_nlink == 1)
        require(target_metadata.st_size == len(payload))
        require((target_metadata.st_dev, target_metadata.st_ino) == (
            anonymous_metadata.st_dev, anonymous_metadata.st_ino
        ))
        safe_fsync(anonymous_fd)
        safe_fsync(directory_fd)
        checkpoint("after_directory_sync", stop_stage)
    except BaseException:
        if published and anonymous_metadata is not None:
            unlink_published_if_owned(directory_fd, basename, anonymous_metadata)
        raise
    finally:
        if anonymous_fd >= 0:
            os.close(anonymous_fd)
        os.close(directory_fd)


try:
    main()
except AnonymousPublishingUnsupported:
    os._exit(UNSUPPORTED_STATUS)
except BaseException as error:
    emit_test_diagnostic(error)
    os._exit(1)
PY
  then
    helper_rc=0
  else
    helper_rc=$?
  fi
  if ((helper_rc == 73)); then
    printf '错误：当前文件系统不支持安全的匿名 apply package 发布，已拒绝生成。\n' >&2
    return 1
  fi
  ((helper_rc == 0)) || return 1
  if ! landing_apply_package_json_is_valid "$output" ||
     ! landing_apply_package_is_fresh "$output" "$issued_at"; then
    if [[ "$test_diagnostics" == true ]]; then
      printf 'landing apply helper test diagnostic: shell-post-validation\n' >&2
    fi
    rm -f -- "$output"
    sync_transaction_path "$output_dir" || true
    return 1
  fi
  controller_state_file_is_trusted "$output"
}

validate_landing_receipt_json() {
  local receipt="$1"
  jq -e -s 'length == 1' "$receipt" >/dev/null || return 1
  jq -e --argjson schema "$LANDING_RECEIPT_SCHEMA_VERSION" '
    type == "object" and
    (keys | sort) == [
      "applied_revision", "content_sha256", "emergency_override", "landing_id",
      "nonce", "role", "schema_version"
    ] and
    .schema_version == $schema and
    .role == "managed-landing" and
    (.landing_id | type == "string" and test("^[a-z][a-z0-9-]{0,31}$")) and
    (.applied_revision | type == "number" and . == floor and . >= 0 and . <= 9007199254740991) and
    (.emergency_override | type == "boolean") and
    (if .applied_revision == 0 then
       .content_sha256 == null and .nonce == null
     else
       (.content_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
       (.nonce | type == "string" and test("^[0-9a-f]{64}$"))
     end)
  ' "$receipt" >/dev/null
}

validate_landing_receipt_file() {
  local receipt="${1:-$LANDING_RECEIPT_FILE}"
  controller_state_file_is_trusted "$receipt" || return 1
  validate_landing_receipt_json "$receipt"
}

with_landing_receipt_lock() {
  local callback="$1" lock_dir rc
  shift
  lock_dir="$(dirname "$LANDING_RECEIPT_LOCK_FILE")"
  ensure_controller_private_directory "$lock_dir" || return 1
  [[ ! -L "$LANDING_RECEIPT_LOCK_FILE" ]] || return 1
  exec 6>"$LANDING_RECEIPT_LOCK_FILE" || return 1
  flock -x -w "$LANDING_RECEIPT_LOCK_TIMEOUT" 6 || { exec 6>&-; return 1; }
  "$callback" "$@" 6>&- && rc=0 || rc=$?
  flock -u 6 2>/dev/null || true
  exec 6>&-
  return "$rc"
}

init_landing_receipt_unlocked() {
  local landing_id="$1" state_dir tmp
  landing_id_is_valid "$landing_id" || return 1
  state_dir="$(dirname "$LANDING_RECEIPT_FILE")"
  ensure_controller_private_directory "$state_dir" || return 1
  if [[ -e "$LANDING_RECEIPT_FILE" || -L "$LANDING_RECEIPT_FILE" ]]; then
    validate_landing_receipt_file "$LANDING_RECEIPT_FILE" || return 1
    [[ "$(jq -r '.landing_id' "$LANDING_RECEIPT_FILE")" == "$landing_id" ]]
    return
  fi
  tmp="$(mktemp "$state_dir/.landing-receipt.XXXXXX")" || return 1
  register_temp_path "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! jq -n --argjson schema "$LANDING_RECEIPT_SCHEMA_VERSION" --arg landing_id "$landing_id" '
      {
        schema_version: $schema,
        role: "managed-landing",
        landing_id: $landing_id,
        applied_revision: 0,
        content_sha256: null,
        nonce: null,
        emergency_override: false
      }
    ' > "$tmp" ||
     ! chmod 600 "$tmp" ||
     ! validate_landing_receipt_json "$tmp" ||
     ! sync_transaction_path "$tmp" ||
     ! mv -- "$tmp" "$LANDING_RECEIPT_FILE" ||
     ! sync_transaction_path "$state_dir"; then
    rm -f -- "$tmp"
    return 1
  fi
  validate_landing_receipt_file "$LANDING_RECEIPT_FILE"
}

init_landing_receipt() {
  with_landing_receipt_lock init_landing_receipt_unlocked "$1"
}

landing_apply_replay_decision() {
  local package="$1" receipt="${2:-$LANDING_RECEIPT_FILE}" now="${3:-$(date +%s)}"
  local package_landing receipt_landing package_revision applied_revision package_sha applied_sha
  local package_nonce applied_nonce emergency_override
  landing_apply_package_structure_is_valid "$package" || return 1
  validate_landing_receipt_file "$receipt" || return 1
  package_landing="$(jq -r '.landing_id' "$package")" || return 1
  receipt_landing="$(jq -r '.landing_id' "$receipt")" || return 1
  [[ "$package_landing" == "$receipt_landing" ]] || return 1
  emergency_override="$(jq -r '.emergency_override' "$receipt")" || return 1
  [[ "$emergency_override" == false ]] || return 1
  package_revision="$(jq -r '.revision' "$package")" || return 1
  applied_revision="$(jq -r '.applied_revision' "$receipt")" || return 1
  package_sha="$(jq -r '.content_sha256' "$package")" || return 1
  applied_sha="$(jq -r '.content_sha256 // ""' "$receipt")" || return 1
  package_nonce="$(jq -r '.nonce' "$package")" || return 1
  applied_nonce="$(jq -r '.nonce // ""' "$receipt")" || return 1
  if ((10#$package_revision == 10#$applied_revision)) &&
     [[ "$package_sha" == "$applied_sha" && "$applied_revision" != 0 ]]; then
    printf 'idempotent\n'
    return 0
  fi
  ((10#$package_revision > 10#$applied_revision)) || return 1
  [[ -z "$applied_nonce" || "$package_nonce" != "$applied_nonce" ]] || return 1
  landing_apply_package_is_fresh "$package" "$now" || return 1
  printf 'apply\n'
}

commit_landing_apply_receipt_unlocked() {
  local package="$1" receipt="$2" now="$3" decision tmp state_dir
  local package_revision package_sha package_nonce
  decision="$(landing_apply_replay_decision "$package" "$receipt" "$now")" || return 1
  [[ "$decision" == apply ]] || [[ "$decision" == idempotent ]]
  [[ "$decision" == apply ]] || return 0
  package_revision="$(jq -r '.revision' "$package")" || return 1
  package_sha="$(jq -r '.content_sha256' "$package")" || return 1
  package_nonce="$(jq -r '.nonce' "$package")" || return 1
  state_dir="$(dirname "$receipt")"
  ensure_controller_private_directory "$state_dir" || return 1
  tmp="$(mktemp "$state_dir/.landing-receipt.XXXXXX")" || return 1
  register_temp_path "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! jq \
      --argjson revision "$package_revision" \
      --arg content_sha256 "$package_sha" \
      --arg nonce "$package_nonce" '
        .applied_revision = $revision |
        .content_sha256 = $content_sha256 |
        .nonce = $nonce
      ' "$receipt" > "$tmp" ||
     ! chmod 600 "$tmp" ||
     ! validate_landing_receipt_json "$tmp" ||
     ! sync_transaction_path "$tmp" ||
     ! mv -- "$tmp" "$receipt" ||
     ! sync_transaction_path "$state_dir"; then
    rm -f -- "$tmp"
    return 1
  fi
  validate_landing_receipt_file "$receipt"
}

commit_landing_apply_receipt() {
  local package="$1" receipt="${2:-$LANDING_RECEIPT_FILE}" now="${3:-$(date +%s)}"
  [[ "$receipt" == "$LANDING_RECEIPT_FILE" ]] || return 1
  with_landing_receipt_lock commit_landing_apply_receipt_unlocked "$package" "$receipt" "$now"
}
