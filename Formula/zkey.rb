class Zkey < Formula
  desc "Groth16 proving-key setup and prove/verify library"
  homepage "https://github.com/IceColdCasino/groth16"
  version "0.3.1"
  head "https://github.com/IceColdCasino/groth16.git", branch: "main"

  # Published by the macOS and Linux release workflows. The macOS archive is Metal.
  # The Linux archives compile in Vulkan and use it when a device is present.
  on_macos do
    on_arm do
      url "https://github.com/IceColdCasino/groth16/releases/download/v0.3.1/groth16-0.3.1-macos-aarch64.tar.gz"
      sha256 "a6de0a2a447daea7a59fec6cae5c6be7870e8fa2f4d047dd82216bba47f60ab1"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/IceColdCasino/groth16/releases/download/v0.3.1/groth16-0.3.1-linux-x86_64.tar.gz"
      sha256 "127b1acdbdc3c2cdc5d5ece2748455eaf8b55821282d70d49870b136efdf9369"
    end
    on_arm do
      url "https://github.com/IceColdCasino/groth16/releases/download/v0.3.1/groth16-0.3.1-linux-aarch64.tar.gz"
      sha256 "d7d7fe0081cc32c4f76e73cb41b825c448421c81c3e6b979ef362a87a59a06da"
    end
  end

  option "with-vulkan", "Build the Vulkan backend with glslang and MoltenVK"

  depends_on "zig" => :build if build.head?
  depends_on "glslang" => :build if build.head? && (OS.linux? || build.with?("vulkan"))
  depends_on "vulkan-headers" => :build if build.head? && OS.linux?
  depends_on "molten-vk" if build.head? && build.with?("vulkan") && OS.mac?

  on_macos do
    depends_on macos: :sonoma
    depends_on xcode: :build if build.head?
  end

  def install
    if build.with?("vulkan") && !build.head?
      odie "Vulkan is built from main: brew install --HEAD --with-vulkan icecoldcasino/groth16/zkey"
    end

    if build.head?
      args = ["-Doptimize=ReleaseFast"]
      if OS.linux?
        args << "-Dvulkan=true"
        args << "-Dvulkan-include=#{Formula["vulkan-headers"].opt_include}"
      elsif build.with?("vulkan")
        args << "-Dvulkan=true"
      end

      system "zig", "build", *args

      bin.install "zig-out/bin/zkey"
      bin.install "zig-out/bin/prover"
      include.install "zig-out/include/groth16.h"
      lib.install "zig-out/lib/libgroth16.a"
      if OS.mac?
        bin.install "zig-out/bin/bn254.metallib"
        lib.install "zig-out/lib/libgroth16.dylib"
      else
        lib.install "zig-out/lib/libgroth16.so"
      end
    else
      bin.install Dir["bin/*"]
      lib.install Dir["lib/*"]
      include.install "include/groth16.h"
    end

    if OS.mac?
      system "install_name_tool", "-id", opt_lib/"libgroth16.dylib", lib/"libgroth16.dylib"
      system "codesign", "--sign", "-", "--force", lib/"libgroth16.dylib"
    end
  end

  def caveats
    <<~EOS
      Shared library:
        #{opt_lib}/#{shared_lib}

      groth16.h:
        #{opt_include}/groth16.h

      Link with:
        -L#{opt_lib} -lgroth16 -I#{opt_include}

      `zkey lib` prints the library path and those flags.
      #{caveat_backend}
    EOS
  end

  test do
    assert_match "usage:", shell_output("#{bin}/zkey 2>&1", 1)
    libpath = shell_output("#{bin}/zkey lib").strip
    assert_equal (lib/shared_lib).realpath.to_s, Pathname.new(libpath).realpath.to_s
    assert_predicate include/"groth16.h", :exist?
    assert_predicate bin/"prover", :exist?
    assert_predicate bin/"bn254.metallib", :exist? if OS.mac?
  end

  def shared_lib
    OS.mac? ? "libgroth16.dylib" : "libgroth16.so"
  end

  def caveat_backend
    if OS.linux?
      "Vulkan multiscalar multiplication is compiled in and used when libvulkan.so.1 and a compute device are present. Otherwise the CPU prover runs."
    elsif build.head? && build.with?("vulkan")
      "Vulkan is enabled for testing. The published macOS archive stays on Metal."
    elsif build.head?
      "Vulkan is off. Rebuild with --HEAD --with-vulkan to test it through MoltenVK. The published macOS archive stays on Metal."
    else
      "Installed from the Apple Silicon release. That archive uses Metal. Vulkan ships in the Linux archives."
    end
  end
end
