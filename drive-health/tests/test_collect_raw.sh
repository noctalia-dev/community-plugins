#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
fixture_bin="$project_dir/tests/fixtures/bin"

payload=$(PATH="$fixture_bin:$PATH" sh "$project_dir/scripts/collect_raw.sh")
printf '%s\n' "$payload" | jq -e '
  .schema == 2
  and .collector_version == "2.0.0"
  and (.collection_id | type == "string" and length > 0)
  and (.lsblk.blockdevices | length) == 2
  and (.smart | length) == 2
  and ([.smart[].requested_device] | sort) == ["/dev/nvme0", "/dev/sda"]
  and (.smart[] | select(.requested_device == "/dev/sda") | .payload.test_standby) == true
  and (.smart[] | select(.requested_device == "/dev/nvme0") | .payload.test_standby) == false
  and ([.smart[].exit_code] | all(. == 0))
' >/dev/null

first_collection_id=$(printf '%s\n' "$payload" | jq -er '.collection_id')
second_payload=$(PATH="$fixture_bin:$PATH" sh "$project_dir/scripts/collect_raw.sh")
second_collection_id=$(printf '%s\n' "$second_payload" | jq -er '.collection_id')
if [ "$first_collection_id" = "$second_collection_id" ]; then
  echo "raw collector reused a collection ID" >&2
  exit 1
fi

empty_payload=$(SMARTCTL_EMPTY=1 PATH="$fixture_bin:$PATH" sh "$project_dir/scripts/collect_raw.sh")
printf '%s\n' "$empty_payload" | jq -e '
  (.smart | length) == 2
  and (.smart[] | select(.requested_device == "/dev/sda") | .exit_code) == 2
  and (.smart[] | select(.requested_device == "/dev/sda")
    | .payload.smartctl.messages[0].string) == "smartctl produced no JSON output"
' >/dev/null

output=$(mktemp "${TMPDIR:-/tmp}/noctalia-smart-raw-test.XXXXXX")
PATH="$fixture_bin:$PATH" sh "$project_dir/scripts/collect_raw.sh" --output "$output"
jq -e '.schema == 2 and (.collection_id | type == "string" and length > 0)
  and (.smart | length) == 2' "$output" >/dev/null
mode=$(stat -c '%a' "$output")
if [ "$mode" != "640" ]; then
  echo "raw collector output mode is $mode, expected 640" >&2
  exit 1
fi
rm -f -- "$output"

echo "raw collector tests passed"
