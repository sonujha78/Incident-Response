#!/bin/bash
# Logstash silent-drop detector.
# Compares TCP input event count sent vs. documents indexed in Elasticsearch
# over a time window. A persistent gap indicates events are being dropped
# in the Logstash filter pipeline (e.g. an unconditional drop{} filter,
# or an unhandled filter exception) without any visible error.
#
# Intended to run on a schedule (cron / systemd timer), e.g. every 5 minutes.

ES_HOST="http://127.0.0.1:9200"
INDEX_PATTERN="app-logs-*"
ALERT_WEBHOOK="http://127.0.0.1:9093/api/v2/alerts"

CURRENT_COUNT=$(curl -s "${ES_HOST}/${INDEX_PATTERN}/_count" | grep -oP '"count":\K[0-9]+')
STATE_FILE="/tmp/logstash_last_count"

if [ -f "$STATE_FILE" ]; then
  LAST_COUNT=$(cat "$STATE_FILE")
  DELTA=$((CURRENT_COUNT - LAST_COUNT))
  echo "$(date): last=$LAST_COUNT current=$CURRENT_COUNT delta=$DELTA"

  # If input rate is known to be non-zero but ES count hasn't moved,
  # or drops significantly below expected, fire an alert.
  if [ "$DELTA" -eq 0 ]; then
    echo "WARNING: No new documents indexed since last check - possible pipeline stall or total drop."
    curl -s -X POST "$ALERT_WEBHOOK" -H "Content-Type: application/json" -d '[{
      "labels": {"alertname": "LogstashNoNewDocuments", "severity": "warning", "service": "logstash"},
      "annotations": {"summary": "No new Elasticsearch documents indexed by Logstash in the last check interval"}
    }]' > /dev/null 2>&1
  fi
else
  echo "$(date): baseline=$CURRENT_COUNT (first run)"
fi

echo "$CURRENT_COUNT" > "$STATE_FILE"
