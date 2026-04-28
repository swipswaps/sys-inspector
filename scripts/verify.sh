#!/bin/bash
set -x

LOG_FILE="/var/log/sys-inspector/verify.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================================"
echo "Sys‑Inspector Self‑Verification"
echo "Started: $(date)"
echo "Log: $LOG_FILE"
echo "============================================================"

# 1. Ensure API is running
echo "--- Checking API health ---"
if ! curl -s http://localhost:8765/health | grep -q "OK"; then
    echo "❌ API not healthy – restarting"
    sudo systemctl restart sys-inspector-api.service
    sleep 3
fi

# 2. Test critical endpoints with data presence
ALL_OK=true
for EP in ports connections processes services resources errors; do
    HTTP_CODE=$(curl -o /tmp/curl_${EP}.txt -w "%{http_code}" "http://localhost:8765/api/$EP")
    if [ "$HTTP_CODE" != "200" ]; then
        echo "❌ /api/$EP returned $HTTP_CODE"
        cat /tmp/curl_${EP}.txt
        ALL_OK=false
    else
        LEN=$(jq 'if type=="array" then length else 0 end' /tmp/curl_${EP}.txt)
        if [ "$LEN" -eq 0 ]; then
            echo "❌ /api/$EP returned empty array"
            ALL_OK=false
        else
            echo "✅ /api/$EP -> $LEN entries"
        fi
    fi
    rm -f /tmp/curl_${EP}.txt
done

if [ "$ALL_OK" != "true" ]; then
    echo "❌ API verification failed – check logs"
    exit 1
fi

# 3. Headless browser verification
echo "--- Running headless browser verification ---"
cat > /tmp/verify_headless.js << 'JS_EOF'
const puppeteer = require('puppeteer');
(async () => {
    const browser = await puppeteer.launch({ headless: true, args: ['--no-sandbox'] });
    const page = await browser.newPage();
    page.on('console', msg => console.log('[Browser]', msg.text()));
    await page.goto('http://localhost:8765', { waitUntil: 'domcontentloaded', timeout: 15000 });
    let success = false;
    try {
        await page.waitForFunction(() => {
            const conn = document.querySelector('#connections-list');
            return conn && conn.innerText.includes('ESTAB');
        }, { timeout: 20000 });
        await page.waitForFunction(() => {
            const boot = document.querySelector('#boot-svg rect');
            return boot && boot.getAttribute('width') !== '0';
        }, { timeout: 20000 });
        success = true;
        console.log('✅ Dashboard fully populated');
    } catch(e) {
        console.log('❌ Verification failed:', e.message);
    }
    await browser.close();
    process.exit(success ? 0 : 1);
})();
JS_EOF

export NODE_PATH=$(npm root -g)
export PUPPETEER_EXECUTABLE_PATH=$(which chromium 2>/dev/null || which chromium-browser 2>/dev/null)
node /tmp/verify_headless.js
VERIFY_RESULT=$?

if [ $VERIFY_RESULT -eq 0 ]; then
    echo "============================================================"
    echo "✅✅✅ VERIFICATION SUCCESSFUL – Dashboard fully functional"
    echo "Log: $LOG_FILE"
    echo "============================================================"
    exit 0
else
    echo "==========================================================="
    echo "❌ VERIFICATION FAILED – manual intervention required"
    echo "Log: $LOG_FILE"
    echo "============================================================"
    exit 1
fi
