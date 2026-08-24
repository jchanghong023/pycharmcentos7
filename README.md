# pycharmcentos7

jbr 用 https://github.com/jchanghong023/JetBrainsRuntime 的最新发布版本


下面是测试通过的方案，但是需要修改pycharm,pycharm.sh 直接启动就能用， 把最新的 libc 打包。

根因已确认，修复方案验证通过。

诊断结论

根因：libskiko-linux-x64.so 依赖 CXXABI_1.3.9 / GLIBCXX_3.4.20 / GLIBCXX_3.4.22， 但你的 shell 环境把 /software/public/gcc/4.8.2/centos7/lib64 加到了 LD_LIBRARY_PATH 前面。gcc 4.8.2
自带的 libstdc++.so.6.0.19 太旧，不提供这些符号，导致 JVM 加载 skiko 本地库失败 → Compose/Skia 渲染节点 RenderNodeContext_nMake 抛 UnsatisfiedLinkError。PyCharm 2026.2 使用了新版 Com
 多平台UI，对libstdc++要求比旧版本高得多。

关键证据：
 ldd libskiko-linux-x64.so 报告 CXXABI_1.3.9 not found, 并指向 /software/public/gcc/4.8.2/centos7/lib64/libstdc++.so.6
- 系统/usr/lib64/libstdc++.so.6.0.19 同样不提供这些符号
 /software/public/gcc/13.2.0/lib64/libstdc++.so.6.0.32 提供全部所需符号
- 把 gcc 13.2.0 的 lib 路径前置后，ldd 完全通过，0 个 not found

修复方法（在当前csh中启动PyCharm前设置环境）：

setenv LD_LIBRARY_PATH /software/public/gcc/13.2.0/lib64:/software/public/gcc/13.2.0/lib:${LD_LIBRARY_PATH}
/tmpdata/DFT_PLAT/Lander/j00808874/x64/pycharm-2026.2.1/bin/pycharm.sh. &
或一次性命令：

env LD_LIBRARY_PATH=/software/public/gcc/13.2.0/lib64:/software/public/gcc/13.2.0/lib:${LD_LIBRARY_PATH} /tmpdata/DFT_PLAT/Lander/j00808874/x64/pycharm-2026.2.1/bin/pycharm.sh . &

注意事项：
1. 先 kill 8565或在 PyCharm 里 File → Invalidate Caches / Restart 之前关闭当前已启动的进程，再重新用上面的命令启动。
2. 这是环境层面的问题，不是 PyCharm 本身的 bug。~/.cshrc 里有 ma gcc/4.8.2 这一行（应该是 module 加载），它会污染 LD_LIBRARY_PATH。如果你不希望长期影响其它工具，可以只在启动 PyCharm
 shell里临时前置gcc 13.2.0路径。
3. 如果~/.cshrc 里没有显式 setenv LD LIBRARY PATH .../software/public/gcc/4.8.2/...,那那这个路径是module load gcc/4.8.2自动注入的。可选的长期方案是在~/.cshrc 末尾追加：
setenv LD_LIBRARY_PATH /software/public/gcc/13.2.0/lib64:/software/public/gcc/13.2.0/lib:${LD_LIBRARY_PATH}
3. 但这会影响所有程序，需评估对其它EDA工具的兼容性。保守做法是仅在启动PyCharm时临时设置。
