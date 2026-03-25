#!/bin/sh
set -e

# Copy provisioning to a writable location so we can process templates
rm -rf /tmp/grafana-provisioning
cp -r /etc/grafana/provisioning /tmp/grafana-provisioning

# Substitute env vars in alerting config (scoped to avoid mangling PromQL variables)
sed \
    -e "s|\${GRAFANA_ALERT_EMAIL_ADDRESSES}|${GRAFANA_ALERT_EMAIL_ADDRESSES}|g" \
    -e "s|\${GRAFANA_BLOCK_STALL_SECONDS}|${GRAFANA_BLOCK_STALL_SECONDS}|g" \
    /tmp/grafana-provisioning/alerting/alerting.yaml \
    > /tmp/grafana-provisioning/alerting/alerting.yaml.tmp
mv /tmp/grafana-provisioning/alerting/alerting.yaml.tmp \
    /tmp/grafana-provisioning/alerting/alerting.yaml

export GF_PATHS_PROVISIONING=/tmp/grafana-provisioning

exec /run.sh
