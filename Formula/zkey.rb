class Zkey < Formula
  desc "Groth16 proving-key setup and prove/verify library"
  homepage "https://github.com/IceColdCasino/groth16"
  version "0.1.0"
  head "https://github.com/IceColdCasino/groth16.git", branch: "main"

  # Apple Silicon archive published by the macOS release workflow.
  on_macos do
    on_arm do
      url "https://github.com/IceColdCasino/groth16/releases/download/v0.1.0/groth16-0.1.0-macos-aarch64.tar.gz"
      sha256 "ce2ec9fb03bac9d5fb239a9e40c910603ee1f98acda222ededc46a4989c5df0d"
    end
  end

  option "with-vulkan", "Build the Vulkan backend with glslang and MoltenVK"

  depends_on "zig" => :build if build.head?
  depends_on "glslang" => :build if build.head? && build.with?("vulkan")
  depends_on "molten-vk" if build.head? && build.with?("vulkan")
  depends_on macos: :sonoma

  on_macos do
    depends_on xcode: :build if build.head?
  end

  def install
    if build.with?("vulkan") && !build.head?
      odie "Vulkan is built from main: brew install --HEAD --with-vulkan icecoldcasino/groth16/zkey"
    end

    if build.head?
      args = ["-Doptimize=ReleaseFast"]
      args << "-Dvulkan=true" if build.with?("vulkan")

      system "zig", "build", *args
      system "zig", "build", "-Doptimize=ReleaseFast", chdir: "zkey-setup"

      bin.install "zkey-setup/zig-out/bin/zkey"
      bin.install "zkey-setup/zig-out/bin/bn254.metallib"
      bin.install "zig-out/bin/prover"
      lib.install "zig-out/lib/libgroth16.dylib"
      lib.install "zig-out/lib/libgroth16.a"
      include.install "zig-out/include/groth16.h"
    else
      bin.install Dir["bin/*"]
      lib.install Dir["lib/*"]
      include.install "include/groth16.h"
    end

    system "install_name_tool", "-id", opt_lib/"libgroth16.dylib", lib/"libgroth16.dylib"
    system "codesign", "--sign", "-", "--force", lib/"libgroth16.dylib"
  end

  def caveats
    <<~EOS
      libgroth16.dylib:
        #{opt_lib}/libgroth16.dylib

      groth16.h:
        #{opt_include}/groth16.h

      Link with:
        -L#{opt_lib} -lgroth16 -I#{opt_include}

      `zkey lib` prints the library path and those flags.
      #{if build.head? && build.with?("vulkan")
          "Vulkan is enabled."
        elsif build.head?
          "Vulkan is off. Rebuild with --HEAD --with-vulkan to add glslang and MoltenVK."
        else
          "Installed from the 0.1.0 Apple Silicon release. Vulkan is off in that archive."
        end}
    EOS
  end

  test do
    assert_match "usage:", shell_output("#{bin}/zkey 2>&1", 1)
    libpath = shell_output("#{bin}/zkey lib").strip
    assert_equal (lib/"libgroth16.dylib").realpath.to_s, Pathname.new(libpath).realpath.to_s
    assert_predicate include/"groth16.h", :exist?
    assert_predicate bin/"bn254.metallib", :exist?
    assert_predicate bin/"prover", :exist?
  end
end
