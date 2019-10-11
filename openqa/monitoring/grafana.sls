{% set dashboard_template_folder = '/var/lib/grafana/dashboards/' %}

{% set nodenames = salt['mine.get']('roles:worker', 'nodename', tgt_type='grain').values()|list %} #list of all worker names (no fqdn, just the name)
{% set node_dashboardnames = (nodenames | map('regex_replace', '^(.*)$', 'worker-\\1.json'))|list %} #we name our dashboards "worker-$nodename.json"
{% set manual_dashboardnames = ['webui.dashboard.json', 'webui.services.json'] %}
{% set preserved_dashboards = node_dashboardnames + manual_dashboardnames %}

server-monitoring-software.repo:
  pkgrepo.managed:
    - humanname: Server Monitoring Software
    - baseurl: https://download.opensuse.org/repositories/server:/monitoring/openSUSE_Leap_$releasever/
    - enabled: True
    - gpgautoimport: True
    - require_in:
      - pkg: grafana

  pkg.latest:
    - name: grafana
    - refresh: True

/var/run/grafana:
  file.directory:
    - user: grafana
    - group: grafana
    - mode: 770

reverse-proxy-group:
  group.present:
  - addusers:
    - nginx

/etc/grafana/grafana.ini:
  ini.options_present:
    - separator: '='
    - strict: True
    - sections:
        server:
          protocol: socket
          domain: 'stats.openqa-monitor.qa.suse.de'
          root_url: 'http://stats.openqa-monitor.qa.suse.de'
          socket: '/var/run/grafana/grafana.socket'
        analytics:
          reporting_enabled: false
          check_for_updates: false
        snapshots:
          external_enabled: false
        dashboards:
          versions_to_keep: 40
        users:
          allow_sign_up: false
          allow_org_create: false
        auth.anonymous:
          enabled: true
          org_name: 'SUSE'
          org_role: 'Viewer'
        smtp:
          enabled: true
          host: 'localhost:25'
          from_address: 'osd-admin@suse.de'
          from_name: 'Grafana'

/etc/grafana/provisioning/dashboards/salt.yaml:
  file.managed:
    - source: salt://openqa/monitoring/grafana/salt.yaml

#remove all dashboards which are not preserved (see manual_dashboardnames above)
#and that do not appear in the mine anymore (e.g. decommissioned workers)
dashboard-cleanup:
{% if preserved_dashboards|length > 0 %}
  cmd.run: #this find statement only works if we have at least one dashboard to preserve
    - cwd: {{dashboard_template_folder}}
    - name: find -type f ! -name {{preserved_dashboards|join(' ! -name ')}} -exec rm {} \;
{% else %}
  file.directory: #if we have absolutely no node, just purge the folder
    - name: {{dashboard_template_folder}}
    - clean: True
{% endif %}

#create dashboards manually defined but managed by salt
{% for manual_dashboardname in manual_dashboardnames %}
{{"/".join([dashboard_template_folder, manual_dashboardname])}}: #works even if variables already contain slashes
  file.managed:
    - source: salt://openqa/monitoring/grafana/{{manual_dashboardname}}
    - template: jinja
{% endfor %}

#create dashboards for each worker contained in the mine
#iterating over node_dashboardnames would be cleaner but we need the nodename itself for the template
{% for nodename in nodenames -%}
{{"/".join([dashboard_template_folder, dashboard_name])}}:
  file.managed:
    - source: salt://openqa/monitoring/grafana/worker.json.template
    - template: jinja
    - worker: {{nodename}}
{% endfor %}
