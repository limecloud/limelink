//! 本机网关部署辅助程序；不安装全局依赖或修改系统服务。
#[cfg(unix)]
#[path = "../gateway_deployment.rs"]
mod deployment;

#[cfg(unix)]
fn main() {
    deployment::main();
}

#[cfg(not(unix))]
fn main() {
    eprintln!("{{\"ok\":false,\"code\":\"gateway_installation_platform_unsupported\"}}");
    std::process::exit(1);
}
