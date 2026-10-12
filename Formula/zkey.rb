class Zkey < Formula
  desc "Groth16 proving-key setup and prove/verify library"
  homepage "https://github.com/IceColdCasino/groth16"
  head "https://github.com/IceColdCasino/groth16.git", branch: "main"

  option "with-vulkan", "Build the Vulkan backend with glslang and MoltenVK"

  depends_on "zig" => :build
  depends_on "glslang" => :build if build.with?("vulkan")
  depends_on "molten-vk" if build.with?("vulkan")
  depends_on macos: :sonoma

  on_macos do
    depends_on xcode: :build
  end

  def install
    args = ["-Doptimize=ReleaseFast"]
    args << "-Dvulkan=true" if build.with?("vulkan")

    system "zig", "build", *args
    system "zig", "build", "-Doptimize=ReleaseFast", chdir: "zkey-setup"

    bin.install "zkey-setup/zig-out/bin/zkey"
    bin.install "zkey-setup/zig-out/bin/bn254.metallib"
    lib.install "zig-out/lib/libgroth16.dylib"
    lib.install "zig-out/lib/libgroth16.a"
    include.install "zig-out/include/groth16.h"

    system "install_name_tool", "-id", opt_lib/"libgroth16.dylib", lib/"libgroth16.dylib"
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
      #{if build.with?("vulkan")
          "Vulkan is enabled."
        else
          "Vulkan is off. Rebuild with --with-vulkan to add glslang and MoltenVK."
        end}
    EOS
  end

  test do
    assert_match "usage:", shell_output("#{bin}/zkey 2>&1", 1)
    libpath = shell_output("#{bin}/zkey lib").strip
    assert_equal (lib/"libgroth16.dylib").realpath.to_s, Pathname.new(libpath).realpath.to_s
    assert_predicate include/"groth16.h", :exist?
    assert_predicate bin/"bn254.metallib", :exist?
  end
end
