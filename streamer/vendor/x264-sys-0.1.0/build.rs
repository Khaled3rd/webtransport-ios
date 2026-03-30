fn main() {
    println!("cargo:rustc-link-lib=static=x264");
    println!("cargo:rerun-if-changed=data/x264.h");

    let version_output = std::process::Command::new("pkg-config")
        .args(["--modversion", "x264"])
        .output()
        .expect("pkg-config not found");
    let version_str = String::from_utf8_lossy(&version_output.stdout);
    let buildver: String = version_str.trim().split('.').nth(1).unwrap_or("155").to_string();

    let bindings = bindgen::Builder::default()
        .header("data/x264.h")
        // Ensure the system x264.h is found when cross-compiling (clang may only
        // search the target sysroot and miss /usr/include on the host container).
        .clang_arg("-I/usr/include")
        // Use Rust enums (old bindgen behavior) so x264-0.3.0 code works
        .rustified_enum(".*")
        .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()))
        .generate()
        .expect("Unable to generate x264 bindings");

    let out_dir = std::env::var("OUT_DIR").unwrap();
    let out_path = std::path::PathBuf::from(&out_dir);

    let bindings_str = bindings.to_string();

    // Strip inner attributes (#![...]) to avoid conflicts when included inside a module
    let cleaned: String = bindings_str
        .lines()
        .map(|line| {
            if line.trim_start().starts_with("#![") {
                format!("// (stripped) {line}")
            } else {
                line.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n");

    let final_content = format!(
        "#[allow(dead_code, non_camel_case_types, non_snake_case, non_upper_case_globals, clippy::all)]\n\
         mod _bindings {{\n\
         {cleaned}\n\
         }}\n\
         pub use self::_bindings::*;\n\
         \n\
         pub unsafe fn x264_encoder_open(params: *mut x264_param_t) -> *mut x264_t {{\n\
             _bindings::x264_encoder_open_{buildver}(params)\n\
         }}\n"
    );

    std::fs::write(out_path.join("x264.rs"), final_content)
        .expect("Couldn't write x264.rs");
}
