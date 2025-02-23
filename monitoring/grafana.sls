{% set dashboard_template_folder = '/var/lib/grafana/dashboards/' %}


{% set workernames = salt['mine.get']('roles:worker', 'nodename', tgt_type='grain').values()|list %} #list of all worker names (no fqdn, just the name)
{% set worker_dashboardnames = (workernames | map('regex_replace', '^(.*)$', 'worker-\\1.json'))|list %} #we name our dashboards "worker-$nodename.json"
{% set manual_dashboardnames = ['webui.dashboard.json', 'webui.services.json', 'failed_systemd_services.json', 'automatic_actions.json', 'job_age.json', 'openqa_jobs.json', 'status_overview.json', 'monitoring.json'] %}
{% set genericnames = salt['mine.get']('not G@roles:webui and not G@roles:worker and not G@roles:monitor', 'nodename', tgt_type='compound').values()|list %} #list names of all generic hosts
{% set generic_dashboardnames = (genericnames | map('regex_replace', '^(.*)$', 'generic-\\1.json'))|list %} #we name our dashboards for generic hosts "generic-$nodename.json"
{% set grafana_plugins = ['grafana-image-renderer', 'blackmirror1-singlestat-math-panel'] %}
{% set preserved_dashboards = worker_dashboardnames + generic_dashboardnames + manual_dashboardnames %}

{% from 'openqa/repo_config.sls' import repo %}
server-monitoring-software.repo:
  pkgrepo.managed:
    - humanname: Server Monitoring Software
    - baseurl: http://download.opensuse.org/repositories/server:/monitoring/{{ repo }}
    - gpgautoimport: True
    - refresh: True
    - priority: 105
    - require_in:
      - pkg: grafana

  pkg.latest:
    - name: grafana
    - refresh: False

/var/run/grafana:
  file.directory:
    - user: grafana
    - group: grafana
    - mode: 770

include:
 - monitoring.nginx

reverse-proxy-group:
  group.present:
  - addusers:
    - nginx
  - require:
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
          from_address: 'osd-admins@suse.de'
          from_name: 'Grafana'

/etc/grafana/ldap.toml:
  ini.options_present:
    - separator: '='
    - strict: True
    - sections:
        '[servers]':
          host: '"ldap.suse.de"'
          port: 389
          use_ssl: 'true'
          start_tls: 'true'
          ssl_skip_verify: 'false'
          search_filter: '"(&(uid=%s)(objectClass=account))"'
          search_base_dns: '["dc=suse,dc=de"]'
        servers.attributes:
          name: '"cn"'
          username: '"uid"'
          email: '""'

/etc/grafana/provisioning/dashboards/salt.yaml:
  file.managed:
    - source: salt://monitoring/grafana/salt.yaml

{% for plugin in grafana_plugins %}
install_{{plugin}}:
  cmd.run:
    - name: /usr/sbin/grafana-cli plugins install {{plugin}}
    - runas: grafana
    - creates: /var/lib/grafana/plugins/{{plugin}}
{%- if not grains.get('noservices', False) %}
  service.running:
    - enable: True
    - name: grafana-server.service
    - watch:
      - cmd: install_{{plugin}}
{%- endif %}
{% endfor %}

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
    - source: salt://monitoring/grafana/{{manual_dashboardname}}
    - template: jinja
{% endfor %}

#create dashboards for each worker contained in the mine
#iterating over worker_dashboardnames would be cleaner but we need the workername itself for the template
{% for workername in workernames -%}
{{"/".join([dashboard_template_folder, "worker-" + workername + ".json"])}}: #same as for manual dashboards too
  file.managed:
    - source: salt://monitoring/grafana/worker.json.template
    - template: jinja
    - worker: {{workername}}
{% endfor %}

#create dashboards for each generic host contained in the mine
{% for genericname in genericnames -%}
{% set interfaces = salt['mine.get']("nodename:" + genericname, 'network.interfaces', 'grain').keys()|list %}
{{"/".join([dashboard_template_folder, "generic-" + genericname + ".json"])}}: #same as for manual dashboards too
  file.managed:
    - source: salt://monitoring/grafana/generic.json.template
    - template: jinja
    - generic_host: {{genericname}}
    - host_interface: {{ interfaces[0] }}
{% endfor %}
