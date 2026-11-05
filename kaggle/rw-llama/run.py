# llama.cpp's llama-server built once for Kaggle's T4 (sm_75, CUDA toolkit of the image), so the
# teacher notebooks (kaggle/rw-teach) skip the 30-minute build: /kaggle/working/llama-bin/.
import os, shutil, subprocess, time

T0 = time.time()
TMP = "/kaggle/temp"
os.makedirs(f"{TMP}/cudalib", exist_ok=True)


def sh(cmd):
    print(f"[{(time.time() - T0) / 60:5.1f} min] $ {cmd}", flush=True)
    subprocess.run(cmd, shell=True, check=True)


# No libcuda.so link in the image for CMake's CUDA::cuda_driver: link against the driver library.
real = subprocess.run("find / -path /proc -prune -o -name 'libcuda.so.1' -print 2>/dev/null | head -1",
                      shell=True, capture_output=True, text=True).stdout.strip()
os.symlink(real, f"{TMP}/cudalib/libcuda.so")
sh(f"git clone -q --depth 1 https://github.com/ggml-org/llama.cpp {TMP}/llama.cpp")
sh(f"cd {TMP}/llama.cpp && git log -1 --format='%h %cs' && cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=75 "
   f"-DLLAMA_CURL=OFF -DCUDA_cuda_driver_LIBRARY={TMP}/cudalib/libcuda.so -DCMAKE_BUILD_TYPE=Release > /dev/null "
   f"&& cmake --build build -j{os.cpu_count()} --target llama-server 2>&1 | grep -iE ' error' | head")
shutil.copytree(f"{TMP}/llama.cpp/build/bin", "/kaggle/working/llama-bin")
sh("ls -la /kaggle/working/llama-bin; LD_LIBRARY_PATH=/kaggle/working/llama-bin /kaggle/working/llama-bin/llama-server --version")
open("/kaggle/working/summary.txt", "w").write(f"llama-server built in {(time.time() - T0) / 60:.0f} min\n")
