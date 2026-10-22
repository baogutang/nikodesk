fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    cc::Build::new()
        .cpp(true)
        .file("src/native.mm")
        .flag("-std=c++17")
        .flag("-fobjc-arc")
        .compile("nikodesk_service_native");
    println!("cargo:rustc-link-lib=framework=Foundation");
    println!("cargo:rustc-link-lib=framework=Security");
    println!("cargo:rustc-link-lib=bsm");
    println!("cargo:rerun-if-changed=src/native.mm");
}
