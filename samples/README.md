# 照片回放

在窗口顶部打开来源菜单，选择照片回放，再选一个存有 NEF、JPEG、PNG 或 TIFF 的目录。也可以在仓库根目录运行下面的命令，直接打开自己的照片目录。

```sh
ASTROFIELD_PLAYBACK_DIR="$HOME/Pictures" swift run AstroField
```

要重复比较同一个焦点或曝光设置，可以使用内置模拟相机。同一个随机种子和同一组场景参数会生成相同的星场。
