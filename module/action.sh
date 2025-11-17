#!/bin/sh

PATH=/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:/data/data/com.termux/files/usr/bin:$PATH
MODDIR=/data/adb/modules/playintegrityfix
version=$(grep "^version=" $MODDIR/module.prop | sed 's/version=//g')
FORCE_PREVIEW=1

# lets try to use tmpfs for processing
TEMPDIR="$MODDIR/temp" #fallback
[ -w /sbin ] && TEMPDIR="/sbin/playintegrityfix"
[ -w /debug_ramdisk ] && TEMPDIR="/debug_ramdisk/playintegrityfix"
[ -w /dev ] && TEMPDIR="/dev/playintegrityfix"
mkdir -p "$TEMPDIR"
cd "$TEMPDIR"

echo "[+] PlayIntegrityFix $version"
echo "[+] $(basename "$0")"
printf "\n\n"

sleep_pause() {
	# APatch and KernelSU needs this
	# but not KSU_NEXT, MMRL
	if [ -z "$MMRL" ] && [ -z "$KSU_NEXT" ] && { [ "$KSU" = "true" ] || [ "$APATCH" = "true" ]; }; then
		sleep 5
	fi
}

download_fail() {
	dl_domain=$(echo "$1" | awk -F[/:] '{print $4}')
	echo "$1" | grep -q "\.zip$" && return
	# Clean up on download fail
	rm -rf "$TEMPDIR"
	ping -c 1 -W 5 "$dl_domain" > /dev/null 2>&1 || {
		echo "[!] Unable to connect to $dl_domain, please check your internet connection and try again"
		sleep_pause
		exit 1
	}
	conflict_module=$(ls /data/adb/modules | grep busybox)
	for i in $conflict_module; do 
		echo "[!] Please remove $conflict_module and try again." 
	done
	echo "[!] download failed!"
	echo "[x] bailing out!"
	sleep_pause
	exit 1
}

download() { busybox wget -T 10 --no-check-certificate -qO - "$1" > "$2" || download_fail "$1"; }
if command -v curl > /dev/null 2>&1; then
	download() { curl --connect-timeout 10 -s "$1" > "$2" || download_fail "$1"; }
fi

# Get latest Pixel Beta information
download https://developer.android.com/about/versions PIXEL_VERSIONS_HTML
BETA_URL=$(grep -o 'https://developer.android.com/about/versions/.*[0-9]"' PIXEL_VERSIONS_HTML | sort -ru | cut -d\" -f1 | head -n1)
download "$BETA_URL" PIXEL_LATEST_HTML

# Always use the latest available version page
mv -f PIXEL_LATEST_HTML PIXEL_BETA_HTML

# Get OTA information, specifically for the QPR (Quarterly Platform Release) build
OTA_URL="https://developer.android.com$(grep -o 'href=".*download-ota.*"' PIXEL_BETA_HTML | grep 'qpr' | cut -d\" -f2 | head -n1)"
download "$OTA_URL" PIXEL_OTA_HTML

# Extract device information
MODEL_LIST="$(grep -A1 'tr id=' PIXEL_OTA_HTML | grep 'td' | sed 's;.*<td>\(.*\)</td>;\1;')"
PRODUCT_LIST="$(grep -o 'tr id="[^"]*"' PIXEL_OTA_HTML | awk -F\" '{print $2 "_beta"}')"
OTA_LIST="$(grep 'ota/.*_beta' PIXEL_OTA_HTML | cut -d\" -f2)"

# Get fingerprints for all devices
echo "- Fetching fingerprints for all Pixel Beta devices ..."
device_count=$(echo "$MODEL_LIST" | wc -l)
valid_count=0

# Start JSON array
profiles_json="["
need_comma=false

i=1
while [ $i -le $device_count ]; do
	MODEL=$(echo "$MODEL_LIST" | sed -n "${i}p")
	PRODUCT=$(echo "$PRODUCT_LIST" | sed -n "${i}p")
	OTA=$(echo "$OTA_LIST" | sed -n "${i}p")

	echo "  [$i/$device_count] Processing $MODEL ($PRODUCT) ..."

	# Download metadata and extract fingerprint
	(ulimit -f 2; download "$OTA" "device_metadata") >/dev/null 2>&1
	FINGERPRINT=$(strings "device_metadata" | grep -am1 'post-build=' | cut -d= -f2)
	SECURITY_PATCH=$(strings "device_metadata" | grep -am1 'security-patch-level=' | cut -d= -f2)

	# Add to JSON array if valid
	if [ -n "$FINGERPRINT" ] && [ -n "$SECURITY_PATCH" ]; then
		if [ "$need_comma" = "true" ]; then
			profiles_json="$profiles_json,"
		fi
		need_comma=true

		profiles_json="$profiles_json
    {
        \"FINGERPRINT\": \"$FINGERPRINT\",
        \"MANUFACTURER\": \"Google\",
        \"MODEL\": \"$MODEL\",
        \"SECURITY_PATCH\": \"$SECURITY_PATCH\"
    }"
		valid_count=$((valid_count + 1))
		echo "    ✓ Valid fingerprint found"
	else
		echo "    ✗ Failed to extract fingerprint"
	fi

	rm -f "device_metadata"
	i=$((i + 1))
done

# Close JSON array
profiles_json="$profiles_json
]"

# Validate we have at least one profile
if [ $valid_count -eq 0 ]; then
	echo "[!] No valid profiles found!"
	download_fail "https://dl.google.com"
fi

echo "- Collected $valid_count device profiles"
echo "- Writing profiles to pif.json ..."
echo "$profiles_json" | tee "$TEMPDIR/pif.json"

cat "$TEMPDIR/pif.json" > /data/adb/pif.json
echo "- new pif.json saved to /data/adb/pif.json"

echo "- Cleaning up ..."
rm -rf "$TEMPDIR"

for i in $(busybox pidof com.google.android.gms.unstable); do
	echo "- Killing pid $i"
	kill -9 "$i"
done

echo "- Done!"
sleep_pause
