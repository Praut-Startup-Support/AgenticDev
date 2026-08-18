import pathlib, unittest

ROOT=pathlib.Path(__file__).parents[1]
class RuntimeCompletion(unittest.TestCase):
 def test_preflight_is_fail_closed_for_storage(self):
  s=(ROOT/'tools/runtime-host-check.sh').read_text()
  for invariant in ('cgroup2fs','overlay2','xfs','pquota','prjquota','Supports d_type','seccomp'):
   self.assertIn(invariant,s)
  self.assertNotIn('exit 0',s)
  self.assertIn('exit "$bad"',s)
 def test_installer_runs_hard_gate_and_verifies_upgrade(self):
  s=(ROOT/'install-vps.sh').read_text()
  self.assertIn('runtime-host-check.sh',s);self.assertIn('zůstal v docker group',s);self.assertIn('zůstal v sudo group',s)
  self.assertIn('systemctl is-active --quiet agenticdev-broker.service',s);self.assertIn('broker socket má nebezpečná práva',s)
  self.assertIn('systemctl restart agenticdev-broker.service',s)
  self.assertIn('chown -R 1000:1000 "$ROOT/data/runner"',s)
  self.assertNotIn('rm -rf /srv/agenticdev/workloads',s);self.assertNotIn('rm -rf /srv/agenticdev/repos',s)
 def test_smoke_rejects_privileged_human_accounts(self):
  s=(ROOT/'tools/smoke-vps.sh').read_text()
  self.assertIn("grep -Eq '^(docker|sudo)$'",s);self.assertIn('nebezpečným přímým přístupem',s)
  self.assertNotIn('má účet i skupinu docker',s)
 def test_runner_command_and_smoke_project_query_are_not_split_or_ambiguous(self):
  compose=(ROOT/'vps/docker-compose.yml').read_text();smoke=(ROOT/'tools/smoke-vps.sh').read_text();install=(ROOT/'install-vps.sh').read_text()
  self.assertIn('register --no-interactive --instance $${FORGEJO_INSTANCE} --token $${RUNNER_SECRET}',compose)
  self.assertNotIn('--instance $${FORGEJO_INSTANCE}\n',compose)
  self.assertIn('/v1/work-orders/next?project=$PROJ',smoke)
  self.assertIn('forgejo actions generate-runner-token',install);self.assertIn('data/runner/.runner',install);self.assertIn('[[:space:]]*0',install)
 def test_repeat_workstation_registration_casts_nullable_key_parameters(self):
  s=(ROOT/'control-plane/app/admin.py').read_text()
  self.assertIn('WHEN %s::text IS NOT NULL AND %s::text <>',s)
 def test_forgejo_identity_uses_unix_login_and_handles_duplicate_email(self):
  s=(ROOT/'control-plane/app/admin.py').read_text()
  self.assertIn('_forgejo_add_key(b.login, b.email',s)
  self.assertIn('if r.status_code == 422 and email:',s)
  self.assertIn('create["email"] = f"{login}@agenticdev.local"',s)
 def test_public_mac_bootstrap_contains_no_join_secret(self):
  enroll=(ROOT/'control-plane/app/enroll.py').read_text();generator=(ROOT/'vps/mk-mac-installer.sh').read_text()
  self.assertIn('@router.get("/join/install"',enroll)
  self.assertIn('Join token v souboru NENÍ',generator)
 def test_smoke_fixture_has_runtime_login_and_upgrade_reloads_caddy(self):
  smoke=(ROOT/'tools/smoke-vps.sh').read_text();install=(ROOT/'install-vps.sh').read_text()
  self.assertIn('login:"smoke-test"',smoke);self.assertIn('dc restart caddy',install)
 def test_access_grant_sends_psql_variables_over_stdin(self):
  s=(ROOT/'vps/agenticdev-ctl').read_text();block=s[s.index('  access)'):s.index('  gate)')]
  self.assertIn("printf '%s\\n'",block);self.assertNotIn('-v code="$CODE" -c',block)
 def test_enrollment_worker_sends_psql_variables_over_stdin(self):
  ctl=(ROOT/'vps/agenticdev-ctl').read_text();block=ctl[ctl.index('      sync)'):ctl.index('      add)')]
  self.assertIn("\\\\set id '$eid'",block);self.assertNotIn('-v id="$eid"',block)
 def test_acceptance_never_converts_skip_to_pass(self):
  s=(ROOT/'tools/acceptance-runtime.sh').read_text()
  self.assertIn('PASS=',s);self.assertIn('FAIL=',s);self.assertIn('SKIP=',s);self.assertIn('if (( F != 0 )); then exit 1; fi',s)
  self.assertIn('supply dedicated signed acceptance fixture',s)
  self.assertIn('AGENTICDEV_ACCEPTANCE_REQUIRE_COMPLETE',s)
  self.assertIn('exit 3',s)
  self.assertIn('test: live runtime acceptance',s)

 def test_runner_uses_address_reachable_from_isolated_jobs(self):
  compose=(ROOT/'vps/docker-compose.yml').read_text()
  caddy=(ROOT/'vps/Caddyfile').read_text()
  self.assertIn('FORGEJO_INSTANCE: ${FORGEJO_ROOT_URL:?chybi FORGEJO_ROOT_URL}', compose)
  self.assertNotIn('FORGEJO_INSTANCE: http://forgejo:3000', compose)
  self.assertIn('@runner_git path_regexp runner_git', caddy)
  self.assertIn('info/refs|git-upload-pack|git-receive-pack', caddy)

 def test_gate_cli_does_not_reuse_stdin_for_json_and_python_source(self):
  ctl=(ROOT/'vps/agenticdev-ctl').read_text()
  self.assertIn('GATE_OUT="$OUT" python3', ctl)
  self.assertIn('json.loads(os.environ["GATE_OUT"])', ctl)
  self.assertNotIn("printf '%s' \"$OUT\" | python3 - <<'PY'", ctl)
 def test_protocol_actions_have_exact_schemas(self):
  s=(ROOT/'vps/broker.py').read_text()
  for action in ('start','attach','stop','status','resize','probe'):self.assertIn(f'"{action}":',s)
  self.assertIn('set(r)!=ACTION_KEYS[action]',s)
 def test_git_source_is_only_online_authorization(self):
  s=(ROOT/'vps/broker.py').read_text()
  self.assertIn('a["repo_url"]',s);self.assertNotIn('m["repo"]["url"]',s);self.assertIn('"remote","set-url","origin",a["repo_url"]',s)
 def test_lifecycle_has_an_explicit_terminal_state_machine(self):
  s=(ROOT/'vps/broker.py').read_text()
  self.assertIn('TRANSITIONS={',s)
  self.assertIn('new not in TRANSITIONS[current[0]]',s)
  self.assertIn('"STOPPED":set(),"FAILED":set(),"EXPIRED":set()',s)
 def test_runtime_start_failure_requeues_the_assigned_task(self):
  main=(ROOT/'control-plane/app/main.py').read_text()
  self.assertIn("e.verb='broker_start_failed'",main)
  self.assertIn("UPDATE task SET state='ready'",main)
  self.assertIn('body.get("verb") == "start_failed"',main)
 def test_provider_auth_failure_retries_only_the_callers_assignment(self):
  main=(ROOT/'control-plane/app/main.py').read_text();launcher=(ROOT/'launcher/agenticdev').read_text()
  self.assertIn('"retry": "ready"',main);self.assertIn('owned.workstation_id=%s',main)
  self.assertIn('AUTH_REQUIRED" || "$outcome" == "RATE_LIMITED',launcher)
 def test_upgrade_backfills_membership_and_terminates_stale_sessions(self):
  migration=(ROOT/'control-plane/app/migrate.py').read_text();install=(ROOT/'install-vps.sh').read_text();ctl=(ROOT/'vps/agenticdev-ctl').read_text()
  self.assertIn('SELECT p.id,pr.id FROM project p CROSS JOIN principal pr',migration)
  self.assertIn('loginctl terminate-user "$login"',install);self.assertIn('loginctl terminate-user "$LOGIN"',ctl)
 def test_control_plane_supplies_live_egress_and_creates_pull_request(self):
  cp=(ROOT/'control-plane/app/main.py').read_text();broker=(ROOT/'vps/broker.py').read_text();install=(ROOT/'install-vps.sh').read_text()
  self.assertIn('/v1/broker/pull-request',cp);self.assertIn('/v1/broker/pull-request',broker)
  self.assertIn('egress_allowlist":sorted(live)',cp);self.assertIn('live_egress_policy_missing',broker)
  self.assertIn('"codex":{"chatgpt.com"}',cp);self.assertIn('"claude":{"api.anthropic.com"}',cp)
  self.assertIn('chatgpt.com,api.anthropic.com,registry.npmjs.org',install)
  self.assertIn('"control_plane": CONTROL_PLANE_URL',cp);self.assertIn('CONTROL_PLANE_URL.rstrip("/") + "/v1/events"',cp)
 def test_socket_server_is_bounded(self):
  s=(ROOT/'vps/broker.py').read_text();self.assertIn('ThreadPoolExecutor(max_workers=16',s);self.assertIn('BoundedSemaphore(32)',s);self.assertNotIn('threading.Thread(target=worker',s)
 def test_merge_gate_fails_closed_without_tests_or_human_approval(self):
  s=(ROOT/'control-plane/app/admin.py').read_text()
  self.assertIn('steps.detect.outputs.kind == \'none\'',s);self.assertIn('exit 1',s)
  self.assertEqual(s.count('max(1, cfg.get_int("MERGE_GATE_APPROVALS", 1))'),2)
  self.assertIn('approvals and approvals >= 1',s)
  self.assertIn('apt-get install -y -qq python3 python3-pip python3-pytest',s)
  self.assertIn('python3 -m pytest -q',s)
  self.assertIn('payload["sha"] = existing.json()["sha"]',s)
  self.assertIn('httpx.put(url, headers=headers, json=payload',s)
  self.assertIn('/branch_protections/main",',s)
  self.assertIn('httpx.delete(',s)
 def test_automatic_enrollment_is_queued_and_collision_safe(self):
  enroll=(ROOT/'control-plane/app/enroll.py').read_text();ctl=(ROOT/'vps/agenticdev-ctl').read_text();install=(ROOT/'install-mac.sh').read_text()
  self.assertIn('_RESERVED =',enroll);self.assertIn('login už patří jinému klíči',enroll)
  self.assertIn('@router.get("/join/status/{enrollment_id}")',enroll)
  self.assertIn('      sync)',ctl);self.assertIn("state='failed',error='login patří jinému klíči'",ctl)
  self.assertIn('read -r -s -p "  týmové heslo:',install);self.assertIn('ssh-keygen -q -t ed25519',install)
  self.assertIn('/join/status/$ENROLLMENT_ID',install)
  self.assertIn('účet je ve frontě, čekám na bezpečné vytvoření',install)
  self.assertIn('None if connect == "domain" else _mint_authkey(ip)',enroll)
 def test_enrollment_worker_is_installed_as_timer(self):
  install=(ROOT/'install-vps.sh').read_text();service=(ROOT/'vps/agenticdev-enrollment.service').read_text()
  self.assertIn('systemctl enable --now agenticdev-enrollment.timer',install)
  self.assertIn('ExecStart=/usr/local/bin/agenticdev-ctl user sync',service)
  self.assertIn('ProtectHome=false',service)
  self.assertNotIn('ProtectHome=read-only',service)

 def test_forgejo_bootstrap_does_not_default_to_reserved_admin(self):
  install=(ROOT/'install-vps.sh').read_text()
  self.assertIn('FORGEJO_ADMIN_USER:-agentic-admin',install)
  self.assertNotIn('FORGEJO_ADMIN_USER:-admin}',install)
 def test_native_subscription_providers_replace_pi_runtime(self):
  docker=(ROOT/'pod/Dockerfile').read_text();harness=(ROOT/'pod/harness/harness.py').read_text();broker=(ROOT/'vps/broker.py').read_text();launcher=(ROOT/'launcher/agenticdev').read_text()
  self.assertIn('@anthropic-ai/claude-code @openai/codex',docker);self.assertNotIn('pi-coding-agent',docker)
  self.assertIn('from providers import command',harness);self.assertNotIn('shutil.which("pi")',harness)
  self.assertIn('provider_denied',broker);self.assertIn('/home/node/.claude',broker);self.assertIn('/home/node/.codex',broker)
  self.assertIn('provider_probe claude',launcher);self.assertIn('provider_probe codex',launcher)
 def test_installed_vps_can_verify_and_apply_official_release_updates(self):
  ctl=(ROOT/'vps/agenticdev-ctl').read_text();launcher=(ROOT/'launcher/agenticdev').read_text()
  self.assertIn('platform_update()',ctl)
  self.assertIn('bash "$SRC/install.sh" "${bootstrap_args[@]}" --check',ctl)
  self.assertIn('bash "$SRC/install.sh" "${bootstrap_args[@]}" -- --yes',ctl)
  self.assertIn('update --tag vX.Y.Z',ctl)
  self.assertNotIn('raw.githubusercontent.com',ctl)
  self.assertIn('claude auth login --claudeai',launcher)
  self.assertIn('codex login --device-auth',launcher)
 def test_vps_installer_starts_with_persistent_multilingual_tutorial(self):
  install=(ROOT/'install-vps.sh').read_text()
  self.assertIn('Choose language / Vyber jazyk',install)
  self.assertIn('AGENTICDEV_LANG=$AGENTICDEV_LANG',install)
  for code in ('cs','en','de','es','ru','zh','pt','fr','hi','ar'):
   self.assertIn(f'AGENTICDEV_LANG={code}',install)
  self.assertIn('installation_tutorial()',install)
  self.assertIn('Welcome. This wizard will install',install)
  self.assertIn('Vítej. Tento průvodce nainstaluje',install)
  self.assertIn('Model subscriptions are personal',install)
  self.assertIn('Modelová předplatná jsou osobní',install)
  for sample in ('Willkommen.','Bienvenido.','Добро пожаловать.','欢迎。',
                 'Bem-vindo.','Bienvenue.','स्वागत है।','مرحباً.'):
   self.assertIn(sample,install)
 def test_repository_analysis_is_versioned_cited_and_gates_work_orders(self):
  migrate=(ROOT/'control-plane/app/migrate.py').read_text();repo=(ROOT/'control-plane/app/repository.py').read_text();main=(ROOT/'control-plane/app/main.py').read_text()
  self.assertIn('CREATE TABLE IF NOT EXISTS provider_profile',migrate)
  self.assertIn('CREATE TABLE IF NOT EXISTS repository_analysis',migrate)
  self.assertIn('UNIQUE (project_id, commit_sha, analyzer_version)',migrate)
  scan=(ROOT/'control-plane/app/repo_scan.py').read_text()
  self.assertIn('untrusted_executable_instructions',scan);self.assertIn('blob_sha',repo)
  self.assertIn('ANALYSIS_REQUIRED',main);self.assertIn('ra.approved_at IS NOT NULL',main)
  self.assertIn('analysis: bool = False',main);self.assertIn('"mode": "analysis" if analysis else "work"',main)
  self.assertIn('/analysis/propose-pr',repo);self.assertIn('explicitní potvrzení',repo)
  analysis=(ROOT/'pod/harness/analysis_runner.py').read_text();broker=(ROOT/'vps/broker.py').read_text()
  self.assertIn('/analysis-output',analysis);self.assertIn('dst=/analysis-output',broker)
  self.assertIn('_post(policy, "failure"',analysis);self.assertIn("state='failed'",repo)
  self.assertIn('repository analysis must contain at least one citation',repo)
 def test_forgejo_runner_never_receives_host_docker_socket(self):
  compose=(ROOT/'vps/docker-compose.yml').read_text()
  runner=compose[compose.index('  runner-docker:'):compose.index('  # ─── Artefakty')]
  self.assertNotIn('/var/run/docker.sock',runner)
  self.assertIn('27-dind',runner);self.assertNotIn('dind-rootless',runner)
  self.assertIn('runner-isolated',runner);self.assertIn('/var/lib/docker',runner)
 def test_worker_roles_have_separate_budget_and_verifiable_output_contract(self):
  main=(ROOT/'control-plane/app/main.py').read_text();director=(ROOT/'pod/harness/director.py').read_text()
  self.assertIn('"budget_tokens": 20_000',main)
  self.assertIn('agenticdev.worker-report/v1',main);self.assertIn('output_schema',director)
 def test_default_branch_push_queues_incremental_analysis(self):
  hooks=(ROOT/'control-plane/app/hooks.py').read_text();admin=(ROOT/'control-plane/app/admin.py').read_text()
  self.assertIn('refs/heads/{default_branch}',hooks);self.assertIn('queue_static_scan',hooks)
  self.assertIn('"pull_request", "push"',admin)
 def test_curated_skill_bundle_is_pinned_and_provider_neutral(self):
  root=ROOT/'workspace/_base/.agenticdev/skills';provenance=(root/'PROVENANCE.json').read_text()
  self.assertIn('068b6e0c62393147daf03530149cdce209c93da8',provenance);self.assertIn('"license": "MIT"',provenance)
  for name in ('diagnosing-bugs','tdd','codebase-design','code-review','research','writing-for-agents','domain-modeling'):
   self.assertTrue((root/name/'SKILL.md').is_file())
  self.assertFalse((root/'karpathy').exists())
 def test_device_auth_requires_single_use_ed25519_proof(self):
  main=(ROOT/'control-plane/app/main.py').read_text();launcher=(ROOT/'launcher/agenticdev').read_text();migration=(ROOT/'control-plane/app/migrate.py').read_text()
  self.assertIn('/v1/auth/device/challenge',main);self.assertIn('key.verify(signature, row["nonce"].encode())',main)
  self.assertIn('used_at IS NULL RETURNING id',main);self.assertIn('CREATE TABLE IF NOT EXISTS device_challenge',migration)
  self.assertIn('load_ssh_private_key',launcher);self.assertIn("'{challenge_id:$c,signature:$s}'",launcher)

if __name__=='__main__':unittest.main()
