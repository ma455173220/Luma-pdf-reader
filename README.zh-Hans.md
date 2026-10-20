<div align="center">

<img src="docs/media/icon.png" width="128" alt="知白图标">

# 知白 Luma

一个读论文用的 macOS PDF 阅读器，小而轻。

知白守墨，去繁存真

[下载](https://github.com/ma455173220/Luma-pdf-reader/releases/latest) · [English](README.md)

</div>

「知白」是说懂得留白：书法里，纸上空着的地方和墨一样要紧。知白只留下读论文用得着的东西，其余的都不做。没有文献库，不用账号，不同步，离线使用，内存占得少：同一篇论文、同一台 Mac 上，比 Skim 少用约三分之一。

## 预览

<img src="docs/media/preview.gif" width="820" alt="引用、图、表的预览，然后把预览钉住">

鼠标停在 [12] 这样的引用上，参考文献就出现在正在读的地方；图和表的引用也一样。论文本身没有可点的链接也没关系，知白会从文字里认出引用、图表和大纲，认不准的就不显示。预览可以钉住、挪动、调大小、缩放、复制里面的字，参考文献可以直接去 Google Scholar 搜。

## 批注

<img src="docs/media/annotations.gif" width="820" alt="高亮、下划线、删除线和附注">

高亮、下划线、删除线，四种颜色，都能加附注。批注存成普通的 PDF 批注，就在文件里，预览等别的阅读器也看得到。保存只在文件末尾追加，不改动原有内容。

## 页面

<img src="docs/media/page-editing.gif" width="820" alt="旋转、换位、插入页面">

在缩略图里旋转、删除、拖动换位，把另一份 PDF 拖进来就能插入或合并。

## 放大镜

<img src="docs/media/magnifier.gif" width="820" alt="放大镜在图上移动">

鼠标所在处按三倍重新画清楚，看图里的小字。

另外还有标签页、缩略图和大纲、查找、返回与前进，复制时会把断行接好。界面有英文和简体中文。

## 安装

需要 Apple 芯片的 Mac，macOS 26 或更新。从 [Releases](https://github.com/ma455173220/Luma-pdf-reader/releases/latest) 下载 zip，解压后把「知白.app」放进「应用程序」。程序没有经过苹果公证，第一次打开会被拦下：到「系统设置 › 隐私与安全性」里点「仍要打开」。

自己构建（需要 Xcode 27 命令行工具）：

```sh
scripts/build-app.sh    # 生成 build/知白.app
```

## 说明

认引用、图表和大纲的思路参考了 [Zotero](https://www.zotero.org) 阅读器的做法，代码是自己写的。演示用的是 arXiv 论文 [2610.12925](https://arxiv.org/abs/2610.12925)、[2609.16780](https://arxiv.org/abs/2609.16780) 和 [2609.24897](https://arxiv.org/abs/2609.24897)，都是 CC BY 4.0。

MIT 许可证。
