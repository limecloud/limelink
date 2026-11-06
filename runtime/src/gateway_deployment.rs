use fs2::FileExt;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    net::Ipv4Addr,
    os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt},
    path::{Component, Path, PathBuf},
    process::Stdio,
    time::Duration,
};
use tokio::{io::AsyncReadExt, process::Command};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
const RUNTIME_FILES: &[&str] = &[
    "upstream/LICENSE",
    "upstream/deploy/dev/config.json",
    "upstream/deploy/nas/manage.py",
    "upstream/deploy/nas/device_identity.py",
    "upstream/deploy/nas/media_state.py",
    "upstream/deploy/nas/platform_install.py",
    "upstream/deploy/nas/nginx.conf",
    "desktop.json",
];

fn require(condition: bool, code: &str) -> Result<()> {
    if condition {
        Ok(())
    } else {
        Err(code.into())
    }
}
fn sha(path: &Path) -> Result<String> {
    let mut file = File::open(path)?;
    let mut hash = Sha256::new();
    let mut buffer = [0; 1024 * 1024];
    loop {
        let size = file.read(&mut buffer)?;
        if size == 0 {
            break;
        }
        hash.update(&buffer[..size]);
    }
    Ok(hex::encode(hash.finalize()))
}
fn checksum(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}
fn image_id(value: &str) -> bool {
    value.strip_prefix("sha256:").is_some_and(checksum)
}
fn regular(root: &Path, relative: &str) -> Result<PathBuf> {
    require(
        Path::new(relative)
            .components()
            .all(|c| matches!(c, Component::Normal(_))),
        "invalid_package_path",
    )?;
    let mut path = root.to_path_buf();
    for part in Path::new(relative).components() {
        path.push(part);
        require(
            !fs::symlink_metadata(&path)?.file_type().is_symlink(),
            "package_symlink_refused",
        )?;
    }
    let metadata = fs::metadata(&path)?;
    require(
        metadata.is_file() && metadata.nlink() == 1,
        "package_regular_file_required",
    )?;
    Ok(path)
}
fn json_file<T: for<'de> Deserialize<'de>>(path: &Path) -> Result<T> {
    require(fs::metadata(path)?.len() <= 262_144, "metadata_too_large")?;
    Ok(serde_json::from_slice(&fs::read(path)?)?)
}
fn save(path: &Path, value: &impl Serialize) -> Result<()> {
    let pending = path.with_extension("next");
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&pending)?;
    file.write_all(&serde_json::to_vec_pretty(value)?)?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    fs::rename(&pending, path)?;
    File::open(path.parent().ok_or("missing_parent")?)?.sync_all()?;
    Ok(())
}
fn private_directory(path: &Path) -> Result<()> {
    fs::create_dir(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}
fn origin(host: &str, https: u16, mqtt: u16) -> Result<String> {
    let ip: Ipv4Addr = host.parse().map_err(|_| "local_ipv4_required")?;
    require(ip.is_loopback() || ip.is_private(), "local_ipv4_required")?;
    require(
        https >= 1024 && mqtt >= 1024 && https != mqtt,
        "distinct_unprivileged_ports_required",
    )?;
    Ok(format!("https://{ip}:{https}"))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Upstream {
    repository: String,
    revision: String,
    worktree_overlay: bool,
    archive_sha256: String,
    #[serde(default)]
    artifact_source_digest: Option<String>,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Images {
    gateway: String,
    edge: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Bundle {
    schema_version: u32,
    kind: String,
    upstream: Upstream,
    platform: String,
    images: Images,
    files: BTreeMap<String, String>,
    distribution: String,
}
impl Bundle {
    fn read(root: &Path) -> Result<Self> {
        let this: Self = json_file(&regular(root, "bundle.json")?)?;
        let sdk: Value = serde_json::from_str(include_str!("../../contracts/iot-sdk.lock.json"))?;
        require(
            this.schema_version == 1
                && this.kind == "limelink.local-gateway"
                && this.upstream.repository == sdk["repository"]
                && this.upstream.revision == sdk["head"]
                && !this.upstream.worktree_overlay
                && checksum(&this.upstream.archive_sha256)
                && this
                    .upstream
                    .artifact_source_digest
                    .as_ref()
                    .is_none_or(|s| checksum(s))
                && this.distribution == "development_unsigned",
            "unsupported_gateway_bundle",
        )?;
        require(
            matches!(this.platform.as_str(), "linux/arm64" | "linux/amd64")
                && image_id(&this.images.gateway)
                && image_id(&this.images.edge)
                && this.images.gateway != this.images.edge,
            "invalid_bundle_images",
        )?;
        require(
            this.files.len() == RUNTIME_FILES.len() + 1
                && this.files.contains_key("images.tar")
                && RUNTIME_FILES
                    .iter()
                    .all(|name| this.files.contains_key(*name)),
            "invalid_bundle_files",
        )?;
        for (name, expected) in &this.files {
            require(
                checksum(expected) && sha(&regular(root, name)?)? == *expected,
                "bundle_checksum_mismatch",
            )?;
        }
        require(
            this.files["desktop.json"]
                == hex::encode(Sha256::digest(include_bytes!(
                    "../../contracts/desktop.json"
                ))),
            "desktop_contract_mismatch",
        )?;
        Ok(this)
    }
}

async fn execute(program: &Path, args: &[String], seconds: u64, capture: bool) -> Result<Vec<u8>> {
    execute_environment(program, args, seconds, capture, None).await
}
async fn execute_environment(
    program: &Path,
    args: &[String],
    seconds: u64,
    capture: bool,
    host: Option<&str>,
) -> Result<Vec<u8>> {
    let mut command = Command::new(program);
    command
        .args(args)
        .kill_on_drop(true)
        .stdin(Stdio::null())
        .stderr(Stdio::null());
    for key in [
        "COMPOSE_FILE",
        "COMPOSE_PROJECT_NAME",
        "COMPOSE_PROFILES",
        "COMPOSE_ENV_FILES",
        "COMPOSE_PATH_SEPARATOR",
    ] {
        command.env_remove(key);
    }
    command.env("COMPOSE_DISABLE_ENV_FILE", "1");
    if let Some(host) = host {
        command
            .env("DOCKER_HOST", host)
            .env_remove("DOCKER_CONTEXT");
    }
    command.stdout(if capture {
        Stdio::piped()
    } else {
        Stdio::null()
    });
    let mut child = command.spawn().map_err(|_| "deployment_tool_unavailable")?;
    let work = async {
        let mut bytes = Vec::new();
        if let Some(output) = child.stdout.take() {
            output.take(262_145).read_to_end(&mut bytes).await?;
            require(bytes.len() <= 262_144, "deployment_tool_output_limit")?;
        }
        require(child.wait().await?.success(), "deployment_tool_failed")?;
        Ok(bytes)
    };
    tokio::time::timeout(Duration::from_secs(seconds), work)
        .await
        .map_err(|_| "deployment_timeout_query_original")?
}

struct Engine {
    docker: PathBuf,
    compose: Option<PathBuf>,
    host: String,
}
impl Engine {
    async fn local(docker: PathBuf, compose: Option<PathBuf>) -> Result<Self> {
        let host = match std::env::var("DOCKER_HOST") {
            Ok(value) if !value.is_empty() => value,
            _ => {
                let bytes = execute(
                    &docker,
                    &[
                        "context".into(),
                        "inspect".into(),
                        "--format".into(),
                        "{{json .Endpoints.docker.Host}}".into(),
                    ],
                    15,
                    true,
                )
                .await?;
                serde_json::from_slice::<String>(&bytes)?
            }
        };
        let socket = host
            .strip_prefix("unix://")
            .ok_or("local_docker_socket_required")?;
        require(
            Path::new(socket).is_absolute() && fs::metadata(socket)?.file_type().is_socket(),
            "local_docker_socket_required",
        )?;
        Ok(Self {
            docker,
            compose,
            host,
        })
    }
    async fn docker(&self, args: &[String], seconds: u64, capture: bool) -> Result<Vec<u8>> {
        let mut values = vec!["--host".into(), self.host.clone()];
        values.extend_from_slice(args);
        execute_environment(&self.docker, &values, seconds, capture, Some(&self.host)).await
    }
    async fn verify_images(&self, images: &Images, platform: &str, revision: &str) -> Result<()> {
        for (role, image) in [("gateway", &images.gateway), ("edge", &images.edge)] {
            let bytes = self
                .docker(&["image".into(), "inspect".into(), image.clone()], 15, true)
                .await?;
            let info: Vec<Value> = serde_json::from_slice(&bytes)?;
            require(
                info.len() == 1
                    && info[0]["Id"] == *image
                    && format!(
                        "{}/{}",
                        info[0]["Os"].as_str().unwrap_or_default(),
                        info[0]["Architecture"].as_str().unwrap_or_default()
                    ) == platform,
                "installed_image_mismatch",
            )?;
            if role == "gateway" {
                require(
                    info[0]["Config"]["Labels"]["org.opencontainers.image.revision"] == revision,
                    "gateway_image_revision_mismatch",
                )?;
            }
        }
        Ok(())
    }
    async fn compose(
        &self,
        root: &Path,
        meta: &Installation,
        operation: &[&str],
        capture: bool,
    ) -> Result<Vec<u8>> {
        let mut args = Vec::new();
        let program = if let Some(compose) = &self.compose {
            compose
        } else {
            args.push("compose".into());
            &self.docker
        };
        args.extend([
            "--project-name".into(),
            meta.project.clone(),
            "--project-directory".into(),
            root.to_string_lossy().into(),
            "--file".into(),
            root.join("compose.json").to_string_lossy().into(),
        ]);
        // 独立Compose不接受Docker全局参数，用当前子进程的DOCKER_HOST固定本机引擎。
        if self.compose.is_none() {
            args.splice(0..0, ["--host".into(), self.host.clone()]);
        }
        args.extend(operation.iter().map(|v| (*v).into()));
        execute_environment(program, &args, 100, capture, Some(&self.host)).await
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Installation {
    schema_version: u32,
    project: String,
    origin: String,
    mqtt_port: u16,
    platform: String,
    revision: String,
    images: Images,
    files: BTreeMap<String, String>,
}
fn installed(root: &Path) -> Result<Installation> {
    let meta: Installation = json_file(&regular(root, "deployment.json")?)?;
    let expected_project = format!(
        "limelink-{}",
        &hex::encode(Sha256::digest(root.as_os_str().as_encoded_bytes()))[..16]
    );
    require(
        meta.schema_version == 1
            && meta.project == expected_project
            && image_id(&meta.images.gateway)
            && image_id(&meta.images.edge),
        "invalid_deployment_metadata",
    )?;
    require(
        meta.files.len() == RUNTIME_FILES.len() + 1
            && meta.files.contains_key("compose.json")
            && RUNTIME_FILES
                .iter()
                .all(|name| meta.files.contains_key(&format!("package/{name}"))),
        "invalid_deployment_files",
    )?;
    for (name, expected) in &meta.files {
        require(
            checksum(expected) && sha(&regular(root, name)?)? == *expected,
            "deployment_files_changed",
        )?;
    }
    Ok(meta)
}
fn mount(source: PathBuf, target: &str, readonly: bool) -> Value {
    json!({"type":"bind","source":source.to_string_lossy().replace('$',"$$"),"target":target,"read_only":readonly,"bind":{"create_host_path":false}})
}
fn composition(root: &Path, host: &str, https: u16, mqtt: u16, images: &Images) -> Value {
    let state = root.join("state");
    let common = json!({"restart":"unless-stopped","read_only":true,"cap_drop":["ALL"],"security_opt":["no-new-privileges:true"],"tmpfs":["/tmp:mode=1777,size=32m"]});
    let mut gateway = common.clone();
    gateway["image"] = json!(images.gateway);
    gateway["environment"] = json!({"LIMEIOT_PUBLIC_ORIGIN":format!("https://{host}:{https}")});
    gateway["volumes"] = json!([
        mount(state.join("data"), "/data", false),
        mount(state.join("config"), "/config", true),
        mount(state.join("secrets"), "/secrets", true),
        mount(state.join("broker-tls"), "/broker-tls", true)
    ]);
    gateway["networks"] = json!(["local"]);
    gateway["stop_grace_period"] = json!("15s");
    let mut edge = common;
    edge["image"] = json!(images.edge);
    edge["entrypoint"] = json!([]);
    edge["command"] = json!([
        "nginx",
        "-c",
        "/etc/limeiot/nginx.conf",
        "-g",
        "daemon off;"
    ]);
    edge["ports"] = json!([
        format!("{host}:{https}:8443"),
        format!("{host}:{mqtt}:8883")
    ]);
    edge["depends_on"] = json!({"gateway":{"condition":"service_healthy"}});
    edge["volumes"] = json!([
        mount(
            root.join("package/upstream/deploy/nas/nginx.conf"),
            "/etc/limeiot/nginx.conf",
            true
        ),
        mount(state.join("tls"), "/tls", true),
        mount(state.join("firmware"), "/firmware", true)
    ]);
    edge["networks"] = json!(["local", "ingress"]);
    json!({"services":{"gateway":gateway,"edge":edge},"networks":{"local":{"internal":true},"ingress":{}}})
}
fn owner(root: &Path) -> Result<(u32, u32)> {
    let metadata = fs::symlink_metadata(root)?;
    require(
        metadata.is_dir()
            && !metadata.file_type().is_symlink()
            && metadata.uid() != 0
            && metadata.mode() & 0o077 == 0,
        "private_non_root_directory_required",
    )?;
    Ok((metadata.uid(), metadata.gid()))
}
fn lock(root: &Path) -> Result<File> {
    let file = root.join(".deployment.lock");
    if file.exists() {
        regular(root, ".deployment.lock")?;
    }
    let file = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(file)?;
    file.try_lock_exclusive().map_err(|_| "deployment_busy")?;
    Ok(file)
}

async fn initialize(
    root: &Path,
    bundle_path: &Path,
    host: &str,
    https: u16,
    mqtt: u16,
    engine: &Engine,
) -> Result<Value> {
    let public_origin = origin(host, https, mqtt)?;
    let bundle = Bundle::read(bundle_path)?;
    private_directory(root)?;
    let (uid, gid) = owner(root)?;
    let _guard = lock(root)?;
    save(
        &root.join("operation.json"),
        &json!({"operation":"initialize","state":"preparing","origin":public_origin}),
    )?;
    private_directory(&root.join("package"))?;
    for name in RUNTIME_FILES {
        let target = root.join("package").join(name);
        fs::create_dir_all(target.parent().ok_or("missing_parent")?)?;
        let mut output = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&target)?;
        std::io::copy(&mut File::open(regular(bundle_path, name)?)?, &mut output)?;
        output.sync_all()?;
        require(
            sha(&target)? == bundle.files[*name],
            "package_changed_during_copy",
        )?;
    }
    engine
        .docker(
            &[
                "load".into(),
                "--input".into(),
                regular(bundle_path, "images.tar")?.to_string_lossy().into(),
            ],
            300,
            false,
        )
        .await?;
    engine
        .verify_images(&bundle.images, &bundle.platform, &bundle.upstream.revision)
        .await?;
    let project = format!(
        "limelink-{}",
        &hex::encode(Sha256::digest(root.as_os_str().as_encoded_bytes()))[..16]
    );
    private_directory(&root.join("state"))?;
    let prefix = vec![
        "run".into(),
        "--rm".into(),
        "--name".into(),
        format!("{project}-initialize"),
        "--network".into(),
        "none".into(),
        "--read-only".into(),
        "--cap-drop".into(),
        "ALL".into(),
        "--security-opt".into(),
        "no-new-privileges:true".into(),
        "--user".into(),
        format!("{uid}:{gid}"),
        "--tmpfs".into(),
        "/tmp:mode=1777,size=32m".into(),
        "--mount".into(),
        format!(
            "type=bind,source={},target=/source,readonly",
            root.join("package/upstream").display()
        ),
        "--mount".into(),
        format!(
            "type=bind,source={},target=/state",
            root.join("state").display()
        ),
    ];
    let mut args = prefix.clone();
    args.extend([
        "--entrypoint".into(),
        "python3".into(),
        bundle.images.gateway.clone(),
        "/source/deploy/nas/manage.py".into(),
        "init".into(),
        "--directory".into(),
        "/state".into(),
        "--origin".into(),
        public_origin.clone(),
    ]);
    engine.docker(&args, 120, false).await?;
    // 初始绑定属于当前电脑，并签发独立设备证书；不启动演示设备或隐式启用Agent。
    let space = format!("space-{}", &uuid::Uuid::new_v4().simple().to_string()[..16]);
    let device = format!(
        "desktop-{}",
        &uuid::Uuid::new_v4().simple().to_string()[..16]
    );
    let desktop: Value = json_file(&root.join("package/desktop.json"))?;
    let revision = format!(
        "sha256:{}",
        hex::encode(Sha256::digest(serde_jcs::to_vec(&desktop)?))
    );
    save(
        &root.join("state/config/gateway.json"),
        &json!({"space_id":space,"models":[desktop],"devices":[{"device_id":device,"model_revision":revision}]}),
    )?;
    let gateway_password = fs::read_to_string(root.join("state/secrets/mqtt-passwords"))?
        .lines()
        .find(|line| line.starts_with("gateway:"))
        .ok_or("missing_gateway_password")?
        .to_string();
    fs::write(
        root.join("state/secrets/mqtt-passwords"),
        gateway_password + "\n",
    )?;
    fs::write(root.join("state/config/mqtt-acl"),format!("user gateway\ntopic read limeiot/v1/{space}/+/up/+\ntopic write limeiot/v1/{space}/+/down/+\nuser {device}\ntopic read limeiot/v1/{space}/{device}/down/+\ntopic write limeiot/v1/{space}/{device}/up/+\n"))?;
    private_directory(&root.join("enrollment"))?;
    let mut issue = prefix;
    let name_index = issue
        .iter()
        .position(|v| v == "--name")
        .ok_or("missing_container_name")?
        + 1;
    issue[name_index] = format!("{project}-enrollment");
    issue.extend([
        "--mount".into(),
        format!(
            "type=bind,source={},target=/enrollment",
            root.join("enrollment").display()
        ),
        "--entrypoint".into(),
        "python3".into(),
        bundle.images.gateway.clone(),
        "/source/deploy/nas/device_identity.py".into(),
        "issue".into(),
        "--directory".into(),
        "/state".into(),
        "--device-id".into(),
        device.clone(),
        "--output".into(),
        "/enrollment/desktop".into(),
    ]);
    engine.docker(&issue, 120, false).await?;
    let identity = root.join("enrollment/desktop");
    let runtime_configuration = root.join("desktop-runtime.json");
    save(
        &runtime_configuration,
        &json!({
            "mqtt_host":host,"mqtt_port":mqtt,"space":space,"device":device,"model_revision":revision,
            "database":identity.join("limelink.sqlite"),"ca":identity.join("ca.crt"),
            "certificate":identity.join("device.crt"),"private_key":identity.join("private.key")
        }),
    )?;
    let mut compose = composition(root, host, https, mqtt, &bundle.images);
    compose["services"]["gateway"]["user"] = json!(format!("{uid}:{gid}"));
    compose["services"]["edge"]["user"] = json!(format!("{uid}:{gid}"));
    save(&root.join("compose.json"), &compose)?;
    let mut files = BTreeMap::new();
    for name in RUNTIME_FILES {
        let relative = format!("package/{name}");
        files.insert(relative.clone(), sha(&root.join(relative))?);
    }
    files.insert("compose.json".into(), sha(&root.join("compose.json"))?);
    let meta = Installation {
        schema_version: 1,
        project,
        origin: public_origin.clone(),
        mqtt_port: mqtt,
        platform: bundle.platform,
        revision: bundle.upstream.revision,
        images: bundle.images,
        files,
    };
    save(&root.join("deployment.json"), &meta)?;
    save(
        &root.join("operation.json"),
        &json!({"operation":"initialize","state":"installed","origin":public_origin}),
    )?;
    Ok(
        json!({"ok":true,"state":"installed","origin":public_origin,"space":space,"desktop_device":device,
            "runtime_configuration":runtime_configuration,"started":false,"agent_enabled":false,"system_trust_changed":false}),
    )
}

#[tokio::main]
pub async fn main() {
    let result = entry().await;
    match result {
        Ok(value) => println!("{value}"),
        Err(error) => {
            eprintln!("{}", json!({"ok":false,"code":error.to_string()}));
            std::process::exit(1)
        }
    }
}
async fn entry() -> Result<Value> {
    let mut args = std::env::args().skip(1);
    let action = args.next().ok_or("missing_action")?;
    require(
        matches!(
            action.as_str(),
            "inspect" | "initialize" | "start" | "stop" | "status"
        ),
        "unsupported_deployment_action",
    )?;
    let mut values = BTreeMap::new();
    while let Some(key) = args.next() {
        require(
            matches!(
                key.as_str(),
                "--bundle"
                    | "--directory"
                    | "--docker"
                    | "--compose"
                    | "--host"
                    | "--https-port"
                    | "--mqtt-port"
            ) && !values.contains_key(&key),
            "invalid_deployment_argument",
        )?;
        values.insert(key, args.next().ok_or("missing_argument_value")?);
    }
    let value = |key: &str| -> Result<&str> {
        values
            .get(key)
            .map(String::as_str)
            .ok_or_else(|| "missing_deployment_argument".into())
    };
    if action == "inspect" {
        let root = Path::new(value("--bundle")?).canonicalize()?;
        let bundle = Bundle::read(&root)?;
        return Ok(
            json!({"ok":true,"platform":bundle.platform,"revision":bundle.upstream.revision,
            "distribution":bundle.distribution,"helper_sources":{
                "runtime/src/gateway_deployment.rs":hex::encode(Sha256::digest(include_bytes!("gateway_deployment.rs"))),
                "runtime/src/bin/limelink-gateway.rs":hex::encode(Sha256::digest(include_bytes!("bin/limelink-gateway.rs")))
            }}),
        );
    }
    let requested = PathBuf::from(value("--directory")?);
    let parent = requested.parent().ok_or("missing_parent")?.canonicalize()?;
    let root = parent.join(requested.file_name().ok_or("missing_directory_name")?);
    // Docker --mount使用CSV；拒绝会改变挂载参数语义的路径。
    require(
        !root.to_string_lossy().contains([',', '\n', '\r']),
        "unsupported_deployment_path",
    )?;
    let engine = Engine::local(
        PathBuf::from(value("--docker")?),
        values.get("--compose").map(PathBuf::from),
    )
    .await?;
    if action == "initialize" {
        let bundle = Path::new(value("--bundle")?).canonicalize()?;
        return initialize(
            &root,
            &bundle,
            value("--host")?,
            value("--https-port")?.parse()?,
            value("--mqtt-port")?.parse()?,
            &engine,
        )
        .await;
    }
    owner(&root)?;
    let _guard = lock(&root)?;
    let meta = installed(&root)?;
    if action == "start" {
        engine
            .verify_images(&meta.images, &meta.platform, &meta.revision)
            .await?;
        engine
            .compose(
                &root,
                &meta,
                &[
                    "up",
                    "--detach",
                    "--no-build",
                    "--pull",
                    "never",
                    "--wait",
                    "--wait-timeout",
                    "75",
                ],
                false,
            )
            .await?;
    } else if action == "stop" {
        engine
            .compose(&root, &meta, &["stop", "--timeout", "15"], false)
            .await?;
    }
    let bytes = engine
        .compose(&root, &meta, &["ps", "--all", "--format", "json"], true)
        .await?;
    let text = std::str::from_utf8(&bytes)?;
    let containers: Vec<Value> = if text.trim_start().starts_with('[') {
        serde_json::from_str(text)?
    } else {
        text.lines()
            .filter(|line| !line.trim().is_empty())
            .map(serde_json::from_str)
            .collect::<std::result::Result<_, _>>()?
    };
    let states: Vec<Value> = containers
        .iter()
        .map(|c| json!({"service":c["Service"],"state":c["State"],"health":c["Health"]}))
        .collect();
    let ready = states.len() == 2
        && states.iter().all(|c| {
            c["state"] == "running" && (c["service"] != "gateway" || c["health"] == "healthy")
        });
    Ok(
        json!({"ok":true,"origin":meta.origin,"state":if ready{"running"}else{"stopped_or_unhealthy"},"services":states,"https_login_verified":false,"data_preserved":true}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn local_installation_refuses_public_hosts_and_ambiguous_ports() {
        assert_eq!(
            origin("192.168.1.20", 8443, 8883).unwrap(),
            "https://192.168.1.20:8443"
        );
        for host in [
            "0.0.0.0",
            "8.8.8.8",
            "gateway.example",
            "127.0.0.1,src=/",
            "127.0.0.1\n",
        ] {
            assert!(origin(host, 8443, 8883).is_err());
        }
        for (https, mqtt) in [(443, 8883), (8443, 188), (8443, 8443), (0, 8883)] {
            assert!(origin("127.0.0.1", https, mqtt).is_err());
        }
    }
    #[test]
    fn compose_has_no_pull_build_or_host_privilege_and_separates_authorities() {
        let images = Images {
            gateway: format!("sha256:{}", "a".repeat(64)),
            edge: format!("sha256:{}", "b".repeat(64)),
        };
        let doc = composition(
            Path::new("/Users/test/$gateway"),
            "127.0.0.1",
            18443,
            18883,
            &images,
        );
        assert_eq!(doc["services"].as_object().unwrap().len(), 2);
        assert_eq!(doc["networks"]["local"]["internal"], true);
        assert_eq!(doc["services"]["edge"]["ports"][0], "127.0.0.1:18443:8443");
        let text = doc.to_string();
        for secret in [
            "device-authority",
            "authority/ca.key",
            "docker.sock",
            "privileged",
            "\"build\"",
        ] {
            assert!(!text.contains(secret));
        }
        assert!(text.contains("$$gateway"));
        assert_eq!(
            doc["services"]["gateway"]["volumes"][0]["bind"]["create_host_path"],
            false
        );
    }
    #[test]
    fn package_refuses_parent_paths_symlinks_and_hardlinks() {
        let root =
            std::env::temp_dir().join(format!("limelink-gateway-check-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        fs::write(root.join("value"), "private").unwrap();
        assert!(regular(&root, "../value").is_err());
        std::os::unix::fs::symlink(root.join("value"), root.join("alias")).unwrap();
        assert!(regular(&root, "alias").is_err());
        fs::hard_link(root.join("value"), root.join("linked")).unwrap();
        assert!(regular(&root, "value").is_err());
        fs::remove_dir_all(root).unwrap();
    }
}
