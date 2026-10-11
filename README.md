# CNI 熔岩冲程引擎崩溃修复

**CNI Lava Stroke Engine NPE Fix** · 仅客户端 · NeoForge 1.21.1 · [MIT 许可证](LICENSE)

修复《机械动力：下界工业》(Create: Nether Industry) 中 **熔岩冲程引擎**
（`createnetherindustry:lava_stroke_engine`，下称 CNI）在客户端**首次渲染即崩溃**的问题：

```text
java.lang.NullPointerException: Cannot invoke
"net.minecraft.client.resources.model.BakedModel.getModelData(...)" because "model" is null
    at ...LavaStrokeEngineRenderer.renderVectorMotionRod(LavaStrokeEngineRenderer.java:366)
```

本模组是一个**独立的修复补丁**，不修改 CNI 本体的 jar。CNI 上游修复之后，直接删掉本模组的 jar 即可。

- 修复对象：`createnetherindustry` 0.2.x（实测 0.2.3）
- 运行环境：Minecraft 1.21.1 + NeoForge 21.1.x（实测 21.1.244）
- 安装侧：**仅客户端安装**，服务端不需要装

## 目录

- [崩溃现象](#崩溃现象)
- [错误原因](#错误原因)
- [修复方式](#修复方式)
- [安装与卸载](#安装与卸载)
- [适配版本](#适配版本)
- [验证修复是否生效](#验证修复是否生效)
- [从源码构建](#从源码构建)
- [已知限制](#已知限制)
- [许可证与作者](#许可证与作者)

## 崩溃现象

只要世界里存在熔岩冲程引擎、并且它被摄像机看到（进入方块实体的渲染剔除范围），客户端就会崩溃。
崩溃报告（`crash-2026-10-11_12.15.47-client.txt`，描述为 `Rendering Block Entity`，已截取关键帧）：

```java
com.google.common.util.concurrent.UncheckedExecutionException: java.lang.NullPointerException:
Cannot invoke "net.minecraft.client.resources.model.BakedModel.getModelData(
net.minecraft.world.level.BlockAndTintGetter, net.minecraft.core.BlockPos,
net.minecraft.world.level.block.state.BlockState, net.neoforged.neoforge.client.model.data.ModelData)"
because "model" is null
    at com.google.common.cache.LocalCache$Segment.get(LocalCache.java:2086)
    at com.google.common.cache.LocalCache.get(LocalCache.java:4012)
    at net.createmod.catnip.render.SuperByteBufferCache.get(SuperByteBufferCache.java:43)
    at net.createmod.catnip.render.CachedBuffers.partial(CachedBuffers.java:47)
    at euphy.upo.createnetherindustry.client.render.LavaStrokeEngineRenderer
            .renderVectorMotionRod(LavaStrokeEngineRenderer.java:366)
    at euphy.upo.createnetherindustry.client.render.LavaStrokeEngineRenderer
            .renderSafe(LavaStrokeEngineRenderer.java:74)
    at com.simibubi.create.foundation.blockEntity.renderer.SafeBlockEntityRenderer
            .render(SafeBlockEntityRenderer.java:28)
    at net.minecraft.client.renderer.blockentity.BlockEntityRenderDispatcher.setupAndRender(...)
```

同一个 NPE 也会在**思索（Ponder）**界面里以“不可致命”的形式出现（被 Ponder 捕获后只打日志）：

```text
[Render thread/ERROR] [Ponder/]: BlockEntity createnetherindustry:lava_stroke_engine could not be rendered virtually.
```

崩溃与否**取决于加载顺序**，而不是取决于存档或配置：只要在“模型烘焙”之前有人（或别的模组）已经触发过 CNI 的
`CNIPartials` 类初始化，同样的方块就能正常渲染。这也是为什么有的整合包会遇到、有的不会。

## 错误原因

熔岩冲程引擎是一个用 Flywheel 渲染的方块实体，它的零件模型走的是 Flywheel 的 **PartialModel（局部模型）** 机制：
局部模型不会被 `BlockModelShaper` 自动烘焙，必须由 Flywheel 显式登记进模型烘焙流程。Flywheel 的登记流程是
（`dev.engine_room.flywheel.lib.model.baked.PartialModelEventHandler`）：

1. 监听 `ModelEvent.RegisterAdditional`：把当前 `PartialModel.ALL` 里已经存在的局部模型登记给这次烘焙；
   该事件由 `ModelBakery` 的构造函数在**工作线程**上触发，**早于** `FMLCommonSetupEvent` 的 deferred work。
2. 监听 `ModelEvent.BakingCompleted`：把烘焙结果写回每个 `PartialModel`。

而 CNI 创建自己的局部模型是在 **late setup** 里：CNI 用 `CNIPartials`（`euphy.upo.createnetherindustry.registry.CNIPartials`）
持有两个局部模型——`cr1`（导杆）、`cr2`（飞轮）：

```java
PartialModel.of(ResourceLocation.fromNamespaceAndPath("createnetherindustry", "block/lava_stroke_engine/cr1"));
PartialModel.of(ResourceLocation.fromNamespaceAndPath("createnetherindustry", "block/lava_stroke_engine/cr2"));
```

`CNIPartials` 第一次被加载是在 `FMLCommonSetupEvent` 的 deferred work（`CNIPartials.init()`）中，此时：

- 上述第 1 步早已执行完毕，`PartialModel.ALL` 里还没有这两个局部模型 → **它们没有被登记**；
- 第 2 步于是给它们留下了 `null`（而且 `PartialModel.ALL` 是**弱引用** map，这些局部模型甚至可能已被 GC 回收）；
- 渲染时 `LavaStrokeEngineRenderer#renderVectorMotionRod` 把该局部模型交给 `CachedBuffers.partial(...)`，
  后者调用 `PartialModel#get()` 拿到 `null`，再交给原版代码取模型数据 → `"model" is null` → 崩溃。

即：**CNI 创建局部模型的时机晚于 Flywheel 收集局部模型的时机**，这是一个纯粹的加载/初始化顺序问题。

## 修复方式

修复分两层：第一层是真正的修复，第二层是兜底（保证最坏情况下“少渲染一个零件”，而不是崩溃）。

### 第 1 层：让局部模型在 Flywheel 收集之前就存在（主修复）

`CNIPartialsBootstrap#registerPartialsEarly(String trigger)` 会在两个时间点主动触发 CNI 的
类初始化（即 CNI 创建局部模型的入口 `CNIPartials.init()`）：

1. **修复模组的构造函数**里——mod 构造发生在一切 common setup（包括 CNI 的 late setup）之前；
2. **`ModelEvent.RegisterAdditional` 的 `EventPriority.HIGHEST`** 上——该事件按优先级依次回调，
   而 Flywheel 使用的是默认优先级，所以本模组一定先执行，局部模型在 Flywheel 收集
   `PartialModel.ALL` 之前就已经存在。

之后流程与正常模组完全一致：Flywheel 登记 → 模型烘焙 → `ModelEvent.BakingCompleted` 写回 →
`PartialModel#get()` 不再返回 `null` → 渲染正常。

另外还有两个防御措施：

- `PartialModel.ALL` 是**弱值** map，所以万一将来 CNI 改了 `CNIPartials` 的类名或字段，本模组会退回
  到用 `PartialModel.of(ResourceLocation)` 自己创建这两个局部模型，并用静态字段强引用保活；
- 无论走哪条路径，都会把这两个模型对应的 `ModelResourceLocation.standalone(...)` 直接注册进
  `ModelEvent.RegisterAdditional`，双保险。

### 第 2 层：渲染器 mixin 兜底

`LavaStrokeEngineRendererMixin` 在 `LavaStrokeEngineRenderer#renderVectorMotionRod` 的 `HEAD`
注入：只要 `part == null || part.get() == null` 就直接 `callback.cancel()`，跳过这一部分渲染
（方块其余部分照常渲染，只是那个零件不画），而不是让原版代码抛出 NPE。

- 注入使用 `require = 0`，且 mixin 配置为 `"required": false`：如果 CNI 以后改动了这个方法，
  mixin 只会**安静地失效**，不会导致游戏启动失败。

### 文件清单

```text
.                                  # 仓库根目录（即 fix-mod/）
├── .gitattributes                             # 统一 LF 行尾（Windows 上跑 .sh 更保险）
├── .gitignore
├── build.sh                                   # 构建脚本（javac + jar，无需 Gradle）
├── verify-launch.sh                           # 启动一次客户端并从日志验证修复
├── LICENSE                                    # MIT
├── README.md
└── src/main/
    ├── java/cc/cszt0/cnilavastrokefix/
    │   ├── LavaStrokeEngineFixMod.java        # 模组入口（@Mod，dist = CLIENT）
    │   ├── CNIPartialsBootstrap.java          # 主修复：提前注册 / 保活 / 验证日志
    │   └── mixin/
    │       └── LavaStrokeEngineRendererMixin.java   # 兜底：跳过未烘焙的零件
    └── resources/
        ├── META-INF/neoforge.mods.toml        # 模组元信息 + 依赖声明
        └── cni_lavastrokefix.mixins.json      # mixin 配置
```

## 安装与卸载

模组 id：`cni_lavastrokefix`，显示名：CNI Lava Stroke Engine NPE Fix。

### 装在客户端还是服务端？

**只需要装在客户端。** 这是一个纯渲染问题的修复：

| 运行侧 | 是否需要安装 | 说明 |
| --- | --- | --- |
| 客户端 | **必须** | 崩溃发生在客户端的方块实体渲染流程里 |
| 集成服务器（单机） | 不需要 | 单机与客户端同进程，只装客户端即可 |
| 专用服务器 | 不需要，也不会生效 | 模组以 `dist = Dist.CLIENT` 声明，服务端不会加载它；装上既不生效也不会报错 |

模组元信息里设置了 `displayTest = "IGNORE_ALL_VERSION"`，因此即使服务端没有安装本模组，
客户端也不会因为“两端模组列表不一致”而被拦下。

### 安装

1. 确认整合包中已安装：Create 6.0+、Flywheel 1.0+（Create 6 内置）、**机械动力：下界工业 0.2+**；
2. 把 `cni_lavastrokefix-1.0.0.jar` 放进 `mods` 文件夹。

`mods` 文件夹的位置取决于启动器是否开启了“版本隔离”：

- 版本隔离**开启**（PCL2 / HMCL 的默认设置）：`.minecraft/versions/<版本名>/mods/`
  例如 `D:\program\Minecraft\.minecraft\versions\1.21.1-NeoForge_21.1.244\mods\`
- 版本隔离**关闭**：`.minecraft/mods/`

### 卸载

删除 `mods/cni_lavastrokefix-1.0.0.jar` 即可。本模组不生成配置文件、不写入存档数据，删除后不留残留。

## 适配版本

| 组件 | 测试过的版本 | 元信息中的依赖要求 | 说明 |
| --- | --- | --- | --- |
| Minecraft | 1.21.1 | `[1.21.1]` | — |
| NeoForge | 21.1.244 | `[21.1.200,)` | 游戏本身需要 Java 21 |
| Create | 6.0.10 | `[6.0.0,)` | 必需 |
| Flywheel | 1.0.6 | `[1.0.0,)` | Create 6 已内置 |
| 机械动力：下界工业 (create-nether-industry) | 0.2.3 | `[0.2.0,)` | 必需，本修复针对它的`lava_stroke_engine` |
| **安装侧** | — | 依赖全部声明为 `side = "CLIENT"` | **仅客户端**安装，服务端无需安装 |

以上依赖均为 `required`：缺少任何一个时，NeoForge 都会在启动时明确提示缺少哪个模组。

> 本修复依赖 CNI 0.2.x 的内部类名（`euphy.upo.createnetherindustry.registry.CNIPartials`）。
> 在更新的 CNI 版本上，第 1 层可能自动退回“自行创建局部模型”的路径，第 2 层 mixin 可能静默失效，
> 两者都不会导致游戏崩溃。若 CNI 官方已修复该问题，直接卸载本模组即可。

## 验证修复是否生效

启动客户端后，`logs/latest.log` 里应出现下面两行（本模组只在客户端加载，因此只会出现在客户端日志中）：

```text
[CNI Lava Stroke Engine Fix] Registered the Lava Stroke Engine partial models through CNIPartials (trigger: mod constructor)
[CNI Lava Stroke Engine Fix] Post-bake state of the Lava Stroke Engine models: rod=OK, flywheel=OK
```

- 第二行里 `rod` / `flywheel` 必须都是 `OK`。如果是 `NOT BAKED (null)`，说明第 1 层没有生效
  （此时第 2 层兜底仍能防止崩溃），请带上日志[提 issue](https://github.com/chushi0/cni-lava-stroke-engine-npe-fix/issues)。
- 如果在 `logs/debug.log` 里能看到下面这行，说明兜底的 mixin 也已经成功注入：

```text
Mixing LavaStrokeEngineRendererMixin from cni_lavastrokefix.mixins.json into euphy.upo.createnetherindustry.client.render.LavaStrokeEngineRenderer
```

- 游戏内验证：在创造模式物品栏的“机械动力：下界工业”分类里找到**熔岩冲程引擎**并放置，
  观察其零件正常渲染、世界不再崩溃。
- 修复前的表现：`logs/latest.log` 中先出现
  `BlockEntity createnetherindustry:lava_stroke_engine could not be rendered virtually.`（思索界面），
  随后在 `crash-reports/` 里生成 `Description: Rendering Block Entity` 的崩溃报告。

## 从源码构建

前置条件：JDK 21（`javac` / `jar`）、Python 3，以及一个**已经安装好上述模组的 NeoForge 实例**。
编译所需的类（Minecraft、NeoForge、Create、Flywheel、CNI 等）全部直接取自该实例，因此
**不需要 Gradle / NeoGradle，也不需要联网下载依赖**。

```bash
bash build.sh             # 构建 → build/libs/cni_lavastrokefix-1.0.0.jar
bash build.sh --install   # 构建并复制到实例的 mods 目录
```

（在仓库根目录执行；克隆下来的目录名无所谓，脚本内部按自身位置定位源码。）

默认路径可用环境变量覆盖（默认值针对 Windows + PCL2 的版本隔离目录布局）：

| 环境变量 | 默认值 | 用途 |
| --- | --- | --- |
| `MC_DIR` | `D:/program/Minecraft/.minecraft` | `.minecraft` 根目录 |
| `VERSION_NAME` | `1.21.1-NeoForge_21.1.244` | 版本文件夹名 |
| `INSTALL_DIR` | `$MC_DIR/versions/$VERSION_NAME/mods` | 安装目标目录 |
| `JAVA_HOME` / `JAVAC` / `JAR_TOOL` / `PYTHON` | 从 `PATH` 自动查找 | 工具链 |

例如在 Linux / macOS 上：
`MC_DIR=~/.local/share/PrismLauncher/instances/1.21.1/minecraft bash build.sh`

`./verify-launch.sh` 会以离线假账号启动一次客户端（仅用于本地验证），把游戏输出写进
`build/launch-stdout.log`；`EXTRA_JVM` 可附加 JVM 参数，例如
`EXTRA_JVM="-Dmixin.debug.export=true"` 会把 mixin 处理后的类导出到 `run/` 目录。

构建产物目录 `build/` 不会进入版本库（见 `.gitignore`）。

## 已知限制

1. 只处理 CNI 0.2.x 的**熔岩冲程引擎**；其它模组里同样“在 late setup 才创建 PartialModel”的问题
   不在范围内（但可以照搬同样的思路修复）。
2. 第 1 层依赖 CNI 的内部类名 `euphy.upo.createnetherindustry.registry.CNIPartials`；类名变化时会自动退回
   “自行创建局部模型”的路径，不会导致崩溃。
3. 第 2 层 mixin 针对 `LavaStrokeEngineRenderer#renderVectorMotionRod` 的方法签名；上游一旦改动，mixin 会
   静默失效（`require = 0` 且 `"required": false`）。
4. 第 1 层假定 Flywheel 在 `ModelEvent.RegisterAdditional` 上使用的是默认优先级监听器（NORMAL）；
   若 Flywheel 未来提升优先级，就不再保证“先注册后收集”，但第 2 层兜底依然有效。
5. 本模组只接触 CNI 那两个局部模型对应的模型位置，不影响其它使用 Flywheel 局部模型的模组。

## 许可证与作者

- 许可证：[MIT](LICENSE)，Copyright (c) 2026 chushi0
- 模组元信息作者（`authors`）：`deepseek-v4-flash`、`Cline` —— 根因分析与修复实现
- 项目发起、测试与发布：`chushi0`（<https://github.com/chushi0>）
