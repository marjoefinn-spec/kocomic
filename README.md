<a id="chinese"></a>

# KoComic — 在 KOReader 里看拷贝漫画

**中文** · [English](#english)

把 [kComics](https://github.com/lxdklp/kComics)(Kindle 越狱 + πthon 的独立 Python 程序)移植成了 KOReader 插件。
接口调用照搬原版,界面推倒重做,并且**能在线边下边看**,下载的书自带正确的阅读设置。

## 和原版的区别

| | kComics(原版) | KoComic(本插件) |
|---|---|---|
| 运行环境 | 越狱 Kindle + πthon(固件 5.16.3+) | 任何能跑 KOReader 的设备(Kindle / Kobo / 安卓…) |
| 阅读方式 | 只能整话下完再看 | **在线边下边看**,也可以下成 CBZ 离线看 |
| 产物 | 转成 MOBI 推进 Kindle 书库 | CBZ + 阅读设置,KOReader 直接打开 |
| 排版 | 按 Kindle 分辨率硬转 | 自动判断条漫 / 跨页扫描 / 单页漫画,分别处理 |
| 观感 | 原样 | 自动色阶去灰 + 每本自带对比度设置 |
| 账号 | 只用来看收藏 | 收藏夹和章节列表里显示账号的阅读进度 |
| 评论 | 看不到 | 每话末尾附上本话吐槽 |
| 域名轮换 | 只能自己改配置 | 一键自动找回 |
| 体积 | 要带 Pillow / lxml / calibre / evdev(几十 MB) | 13 个 Lua 文件,约 130 KB |
| 界面 | 自己往 framebuffer 上画 | KOReader 原生部件,输入法/翻页/手势全是现成的 |

功能上还多了排行榜、人气推荐、章节分组切换、多选下载、书架管理、阅读进度记忆。

## 安装

把 `kocomic.koplugin` 整个文件夹拷到 KOReader 的 plugins 目录:

- Kindle:`/mnt/us/koreader/plugins/kocomic.koplugin`
- Kobo:`/mnt/onboard/.adds/koreader/plugins/kocomic.koplugin`
- 安卓:`/sdcard/koreader/plugins/kocomic.koplugin`

重启 KOReader,入口在 **文件管理器 → 放大镜(搜索)菜单 → 看漫画 KoComic**,
也可以在「手势/快捷键」里把 `看漫画 KoComic` 绑到某个手势上。

## 怎么用

**首页**:搜索 / 最近更新 / 人气推荐 / 排行榜(日周月总)/ 我的收藏(需登录)/ 我的书架 / 设置。

**点开某一话**,有三个去处:

- **在线阅读(边下边看)** —— 不用等整话下完,翻到哪下到哪,读过的图存在缓存里
- **下载这一话 / 从这一话往后下 N 话** —— 打包成 CBZ
- **长按某一话** = 多选,勾几话一起下

**在线阅读器里**:左右两侧点一下翻页,中间点一下出菜单(上一话 / 下一话 / 跳转 / 换排版方式 /
把这一话存成 CBZ / 退出),实体翻页键和左右滑动也管用。退出时记住读到哪,下次接着看。

**下载**时屏幕上显示进度,点一下可以中止;中止后已下好的图片保留,下次接着下。

## 账号里的阅读进度

登录之后,插件会去 `/api/v3/comic2/{漫画}/query` 读账号那边的记录(拷贝漫画 App / 网页版
同步过来的那份),显示在三个地方:

- **收藏夹列表**:每部后面标「读到 第12话」(没有进度就退回显示「最新 第20话」或作者)
- **漫画详情页**:副标题带上「· 读到 第12话」
- **章节列表**:那一话标成「读到这里」,左上角菜单里有「跳到上次读到的那一话」

没登录就什么都不显示(服务器会把 `collect`/`browse` 都返回空,不会报错)。
字段名各家客户端写法不一(`last_browse.last_browse_name`、`browse.chapter_name`、
`chapter_uuid` 都见过),插件一并认了;认不出来就当没有,不会因此出错。

> 说明:这部分我手上没有拷贝漫画账号,只能用未登录的返回值验证「不炸、字段解析对」,
> 登录后的实际显示效果还要你上机看一眼。目前只**读**进度,不会往账号里写。

## 话末的吐槽

拷贝漫画管章节评论叫「吐槽」,接口是 `/api/v3/roasts?chapter_id=…`,**免登录可读**,
一次最多给 100 条,热门章节动辄几百条。

插件默认在**每一话正文后面接上本话吐槽**:排成书页,用户名和日期一行小字,
下面是正文,一条一条用细线隔开,右下角标「吐槽 1/2」。

- **在线阅读**:正文翻完继续往后翻就是吐槽页,页脚显示「本话吐槽」
- **下载的 CBZ**:接在这一话最后,文件名排在正文之后;文字页存成 PNG(比 JPEG 锐利、还更小)
- 合并成一本时,每话的吐槽跟在**各自那一话**后面,不会堆到书尾

设置里可以关掉,或者改「最多附多少条」(默认 40,一话大约排成 2~3 页)。
取不到吐槽(网络、接口变动)时会静默跳过,不影响正文。

## 接口域名换了怎么办

拷贝漫画的接口域名是会轮换的。插件里做了一键找回:**设置 → 接口域名 → 自动查找可用域名**,
或者遇到「连不上接口」时会直接弹出来问你要不要找。

它会挨个探活,命中就停(过程中点屏幕可以中止):先确认当前这个是不是真挂了,
再回头试**以前用通过的**(记在设置里,菜单里也能一键切回),然后是从接口返回内容里读到的线索,
最后是一批内置候选。同一时间通常不止一个域名活着,所以「挨个试」这条路是通的 ——
测试里把域名故意改成不存在的,插件第 2 次尝试就找回来了。

手动填也支持:粘贴 `https://api.xxx.com/` 这种整条 URL 会自动清成域名。

> 注意:**风控(210)不是域名问题**。它是按 IP 限一小时左右(所有域名一起限),
> 所以插件遇到 210 只提示、不会去瞎换域名。

## 设置项

| 设置 | 说明 |
|---|---|
| 账号 | 登录后才能用收藏;部分章节也要登录才给看 |
| 接口域名 | 自动查找 / 手动输入 / 一键切回用过的 |
| 自动找可用接口 | 域名换了就点它,挨个探活换过去 |
| 图片清晰度 | 清晰 1500px(默认)/ 省流 800px |
| 排版方式 | 自动判断(推荐)/ 都当条漫 / 都当单页漫画 |
| 跨页大图拆成两页 | 右→左(日漫,默认)/ 左→右 / 不拆 |
| 重裁后的图片质量 | 只影响条漫重裁出来的页;单页漫画是原图,不重新编码 |
| 裁页尺寸 | 默认就是当前屏幕。换设备看的话建议重新下载 |
| 自动色阶(去灰) | 按每张图拉黑白点,默认开;够黑够白的图不会被动 |
| 连原图一起去灰 | 单页漫画默认保原图不重编码;打开这项才会重新编码 |
| 画面对比度 | 写进书里的伽马,默认 1.5(KOReader 默认 1.0) |
| 话末附上本话吐槽 | 默认开;每话末尾接上章节评论 |
| 最多附多少条 | 默认 40 条,约 2~3 页 |
| 每本 CBZ 装几话 | 1 = 一话一本;调大就是合并 |
| 下载目录 | 默认「主目录/漫画」 |
| 给书架里的书补上阅读设置 | 给老书补写「整页显示」 |
| 清空图片缓存 / 忘掉已下载记录 | |

## 注意事项

- **接口域名随时会变**。返回「网络不可用」或一直加载失败时,先去设置里换域名。
- **风控(错误码 210)**:接口抽风或没登录时会遇到,稍等一会儿,或者登录一个账号。
- 拷贝漫画默认给的是**繁体**书名,这是数据源本身的行为。
- 下载和在线阅读都是单线程的,一话 90 张图要几分钟,期间界面会转菊花 —— KOReader 插件的常态。
- 插件本身不提供任何漫画内容,数据全部来自拷贝漫画的公开接口。

## 目录结构

```
kocomic.koplugin/
├── _meta.lua              插件元信息
├── main.lua               入口:注册菜单和手势
└── kocomic/
    ├── config.lua         配置读写、目录、裁页尺寸
    ├── api.lua            拷贝漫画 API(搜索/详情/章节/图片/登录/收藏)
    ├── imgheader.lua      只读文件头拿图片宽高(纯 Lua)
    ├── imageutil.lua      解码/缩放/拼版/取样/存 JPEG(唯一碰 FFI 的一层)
    ├── levels.lua         自动色阶:直方图 → 映射表(纯 Lua)
    ├── comments.lua       把本话吐槽排版成书页,接在正文后面
    ├── hostfinder.lua     接口域名换了的时候自己找回来
    ├── pager.lua          排版引擎:判型 + 重新裁页 + 找切口 + 去灰
    ├── reader.lua         在线阅读器(边下边看)
    ├── cbz.lua            用 libarchive 打 CBZ 包
    ├── downloader.lua     下载调度、排版打包、阅读设置、已下载记账
    └── browser.lua        界面:首页 / 列表 / 详情 / 书架 / 设置
test/                      电脑上跑的冒烟测试(不用拷到设备上)
```

## 开发:不上机怎么测

`test/` 下有一套冒烟测试:用 lupa 起一个真的 Lua 运行时,`stubs.lua` 假装成 KOReader,
HTTP、zip、文件交给 Python,**图像那层换成 Pillow** —— 于是排版引擎跑的是真代码、真数据。

```bash
pip install lupa pillow
python test/run_test.py                      # 主流程:判型 / 重裁 / 吐槽 / 下载 / 阅读器
python test/run_test.py scenario_ui.lua      # 只测界面骨架和设置项
python test/run_test.py scenario_host.lua    # 只测域名自动查找
```

主流程那套会打不少数据接口,**连着跑几遍会踩到风控**(拷贝漫画按 IP 限一小时左右,
所有域名一起限),这时候它会明说是 210 而不是报一堆乱码;另外两套只打很少的接口,随时能跑。

它会拿三部真漫画各跑一遍判型(条漫 / 跨页扫描 / 单页),验证条漫重裁出来的每页正好一屏、
单页漫画保留原图、生成的书带上了阅读设置,再走一遍在线阅读器的翻页,
最后把生成的 CBZ 拆开报告尺寸,并导出几页 PNG 到 `test/_pages/` 供肉眼检查。

两个测试环境的细节:Windows 的 C 运行时不认 UTF-8 路径(成品文件名全是中文),
所以 stubs 把 `os.rename/os.remove/io.open` 转给了 Python;真机是 Linux,没这问题。

## 许可证

移植自 kComics(作者 lxdklp,GPL-3.0),因此本插件同样以 **GPL-3.0** 发布,见 `LICENSE`。

---

<a id="english"></a>

# KoComic — Read CopyManga in KOReader

[中文](#chinese) · **English**

A KOReader plugin ported from [kComics](https://github.com/lxdklp/kComics), a standalone Python
program for jailbroken Kindles running πthon. The API calls follow the original, the UI was rebuilt
from scratch, it can **stream a chapter while you read it**, and every downloaded book ships with the
right reading settings baked in.

## How it differs from the original

| | kComics (original) | KoComic (this plugin) |
|---|---|---|
| Runs on | Jailbroken Kindle + πthon (firmware 5.16.3+) | Anything that runs KOReader (Kindle / Kobo / Android…) |
| Reading | Whole chapter must finish downloading first | **Streams as you read**, or download to CBZ for offline |
| Output | Converted to MOBI, pushed into the Kindle library | CBZ + reading settings, opens straight in KOReader |
| Layout | Hard-converted to the Kindle's resolution | Detects webtoon / double-page scan / single-page manga and handles each |
| Look | As-is | Auto levels to kill the grey, plus a per-book contrast setting |
| Account | Favourites only | Shows the account's reading progress in favourites and chapter lists |
| Comments | Not visible | Appends the chapter's roasts after each chapter |
| Domain rotation | Edit the config yourself | One tap to find a working one |
| Size | Ships Pillow / lxml / calibre / evdev (tens of MB) | 13 Lua files, about 130 KB |
| UI | Draws onto the framebuffer itself | Native KOReader widgets — IME, paging and gestures all come free |

It also adds rankings, popular picks, chapter group switching, multi-select downloads, a bookshelf
and reading-position memory.

## Installing

Copy the whole `kocomic.koplugin` folder into KOReader's plugins directory:

- Kindle: `/mnt/us/koreader/plugins/kocomic.koplugin`
- Kobo: `/mnt/onboard/.adds/koreader/plugins/kocomic.koplugin`
- Android: `/sdcard/koreader/plugins/kocomic.koplugin`

Restart KOReader. The entry point is **File manager → magnifier (search) menu → 看漫画 KoComic**.
You can also bind `看漫画 KoComic` to a gesture in the gesture manager.

## Using it

**Home**: search / latest updates / popular / rankings (day, week, month, all time) / my favourites
(login required) / my bookshelf / settings.

**Open a chapter** and there are three ways to go:

- **Read online (streaming)** — no waiting for the whole chapter; it fetches as you turn, and pages
  you have read stay in the cache
- **Download this chapter / download N chapters from here** — packed into CBZ
- **Long-press a chapter** = multi-select, tick several and fetch them together

**In the online reader**: tap the left or right edge to turn pages, tap the middle for the menu
(previous chapter / next chapter / jump / change layout mode / save this chapter as CBZ / exit).
Hardware page keys and left-right swipes work too. It remembers where you stopped and resumes there.

**While downloading**, progress is shown on screen and a tap aborts it; images already fetched are
kept, and the next run picks up where it left off.

## Reading progress from your account

Once you are logged in, the plugin reads your account's record via
`/api/v3/comic2/{comic}/query` (the one the CopyManga app or website synced there) and shows it in
three places:

- **Favourites list**: each title is tagged "read up to ch. 12" (falling back to "latest ch. 20" or
  the author when there is no progress)
- **Comic detail page**: the subtitle gains "· read up to ch. 12"
- **Chapter list**: that chapter is marked "you are here", and the top-left menu has "jump to the
  chapter you last read"

Without a login nothing is shown — the server returns `collect` and `browse` empty rather than an
error. Clients spell the fields differently (`last_browse.last_browse_name`, `browse.chapter_name`
and `chapter_uuid` have all been seen in the wild) and the plugin accepts all of them; anything it
cannot parse is treated as absent and never breaks the page.

> Note: I don't have a CopyManga account, so I could only verify against logged-out responses that
> this doesn't crash and that the field parsing is right. How it actually looks once logged in still
> needs a check on a real device. Progress is **read-only** — the plugin never writes back.

## Roasts at the end of a chapter

CopyManga calls its chapter comments "roasts" (吐槽). The endpoint is
`/api/v3/roasts?chapter_id=…`, it is **readable without logging in**, returns at most 100 at a time,
and popular chapters easily run into the hundreds.

By default the plugin **appends that chapter's roasts after its last page**: typeset as book pages,
username and date in small type on one line, the comment below, each separated by a thin rule, with
"roasts 1/2" in the bottom-right corner.

- **Online reading**: keep turning past the last page and you are in the roasts, with "chapter
  roasts" in the footer
- **Downloaded CBZ**: appended at the end of that chapter, filenames sorted after the pages; text
  pages are stored as PNG (sharper than JPEG, and smaller for this kind of content)
- When several chapters are merged into one book, each chapter's roasts follow **its own chapter**
  instead of piling up at the end

You can switch this off in the settings, or change the cap (default 40, roughly 2–3 pages per
chapter). If roasts can't be fetched — network trouble, an API change — they are skipped silently and
the chapter itself is unaffected.

## When the API domain changes

CopyManga rotates its API domains. The plugin has a one-tap recovery:
**Settings → API domain → find a working domain automatically**. It also offers to run this for you
when a request fails with "cannot reach the API".

It probes candidates one at a time and stops at the first hit (tap the screen to abort): first it
confirms whether the current one is genuinely down, then it retries **ones that worked before** (kept
in the settings, and switchable from the menu), then clues read out of the API's own responses, and
finally a set of built-in candidates. More than one domain is usually alive at any given moment, so
working through the list does pay off — in testing, pointing the plugin at a domain that does not
exist had it recovered on the second attempt.

Typing one in by hand works too: paste a full URL like `https://api.xxx.com/` and it is trimmed down
to the host.

> Note: **the rate-limit error (210) is not a domain problem.** It is applied per IP for about an
> hour and covers every domain at once, so on a 210 the plugin only tells you and will not go hunting
> for a new domain.

## Settings

| Setting | What it does |
|---|---|
| Account | Needed for favourites; some chapters also require a login |
| API domain | Auto-find / type one in / switch back to one that worked |
| Find a working API automatically | Tap it when the domain has changed; probes and switches over |
| Image quality | Sharp 1500px (default) / data-saving 800px |
| Layout mode | Auto-detect (recommended) / always webtoon / always single-page |
| Split double-page spreads | Right→left (manga order, default) / left→right / don't split |
| Re-encoded image quality | Only affects pages re-cut from webtoons; single-page manga keeps the original file |
| Page size | Defaults to the current screen. Re-download if you switch devices |
| Auto levels (de-grey) | Stretches the black and white points per image, on by default; images that are already crisp are left alone |
| De-grey originals too | Single-page manga keeps its original file by default; enable this to re-encode |
| Contrast | The gamma written into the book, default 1.5 (KOReader's own default is 1.0) |
| Append chapter roasts | On by default; adds the chapter comments after each chapter |
| Roast cap | Default 40, about 2–3 pages |
| Chapters per CBZ | 1 = one chapter per file; raise it to merge |
| Download directory | Defaults to "home/漫画" |
| Fix reading settings on the shelf | Writes "fit page" into books downloaded earlier |
| Clear image cache / forget download records | |

## Things to know

- **The API domain changes without warning.** If you get "network unavailable" or endless loading,
  go change the domain in the settings first.
- **Rate limiting (error 210)**: happens when the API is having a moment, or when you aren't logged
  in. Wait a while, or log into an account.
- CopyManga serves **traditional Chinese** titles by default — that's the data source, not the plugin.
- Downloading and streaming are both single-threaded; a 90-image chapter takes a few minutes with a
  spinner on screen. That is normal for a KOReader plugin.
- The plugin hosts no comics of its own; everything comes from CopyManga's public API.

## Layout

```
kocomic.koplugin/
├── _meta.lua              plugin metadata
├── main.lua               entry point: registers the menu and gestures
└── kocomic/
    ├── config.lua         settings, directories, page size
    ├── api.lua            CopyManga API (search / detail / chapters / images / login / favourites)
    ├── imgheader.lua      image dimensions straight from the file header (pure Lua)
    ├── imageutil.lua      decode / scale / stitch / sample / write JPEG (the only layer touching FFI)
    ├── levels.lua         auto levels: histogram → lookup table (pure Lua)
    ├── comments.lua       typesets the chapter's roasts into book pages
    ├── hostfinder.lua     finds a working API domain when the old one dies
    ├── pager.lua          layout engine: type detection + re-cutting + seam finding + de-greying
    ├── reader.lua         the streaming online reader
    ├── cbz.lua            packs CBZ files via libarchive
    ├── downloader.lua     download scheduling, packing, reading settings, bookkeeping
    └── browser.lua        UI: home / lists / detail / bookshelf / settings
test/                      smoke tests that run on a PC (no device needed)
```

## Development: testing without a device

`test/` holds a smoke-test suite: lupa starts a real Lua runtime, `stubs.lua` impersonates KOReader,
HTTP, zip and file I/O are handed to Python, and **the imaging layer is swapped for Pillow** — so the
layout engine runs real code against real data.

```bash
pip install lupa pillow
python test/run_test.py                      # main flow: detection / re-cutting / roasts / download / reader
python test/run_test.py scenario_ui.lua      # UI skeleton and settings only
python test/run_test.py scenario_host.lua    # domain auto-discovery only
```

The main flow hits a fair number of data endpoints and **will trip the rate limit if you run it a few
times back to back** (CopyManga limits per IP for about an hour, across every domain at once); when
that happens it says 210 plainly instead of dumping garbage. The other two suites hit very few
endpoints and can be run any time.

It runs type detection against three real comics (webtoon / double-page scan / single-page), checks
that re-cut webtoon pages come out exactly one screen tall, that single-page manga keeps its original
files, and that generated books carry the reading settings; then it walks the online reader's paging,
unpacks the resulting CBZ and reports the dimensions, and exports a few pages as PNG into
`test/_pages/` for eyeballing.

One detail about the test environment: the Windows C runtime can't handle UTF-8 paths (the output
filenames are all Chinese), so the stubs route `os.rename/os.remove/io.open` through Python. Real
devices run Linux and don't have this problem.

## Licence

Ported from kComics (by lxdklp, GPL-3.0), so this plugin is likewise released under **GPL-3.0** —
see `LICENSE`.
