# v007 · 修复地形着色器编译失败（v003 第四节第 1 条阻塞项）

状态：已实施，待评审
覆盖范围：v003 第四节第 1 条「【阻塞】地形着色器疑似编译失败」

---

## 一、一句话结论

**根因是 `light()` 函数里用了 `return`，Godot 明令禁止，导致整个着色器编译失败并回退到默认材质。**

去掉四个诊断分支的 `return`、改为 if/else 链后：着色器编译通过，
八处地标 16 张截图全部正常，19 个调试变体全部生成，DEM 回归自检 9/9 通过。

v003 第七节猜测的第一个怀疑点（「`light()` 里的 `return` 早退分支」）**猜对了**，
只是当时诊断命令被中断没跑完。

---

## 二、真实报错

```
SHADER ERROR: Using 'return' in the 'light' processor function is incorrect.
   at: (null) (:144)
ERROR: Shader compilation failed.
   at: shader_set_code (servers/rendering/dummy/storage/material_storage.cpp:192)
```

出错的是这四行（`client/render/terrain.gdshader` 原第 144–147 行）：

```glsl
if (debug_mode == 5) { DIFFUSE_LIGHT += vec3(ATTENUATION); return; }
if (debug_mode == 6) { DIFFUSE_LIGHT += vec3(ndl * 0.5 + 0.5); return; }
if (debug_mode == 7) { DIFFUSE_LIGHT += vec3(k); return; }
if (debug_mode == 8) { DIFFUSE_LIGHT += LIGHT_COLOR / PI; return; }
```

改成 if / else if / else 链即可，语义完全不变。

**这个坑值得单独记住**：它不是警告而是编译错误，整个着色器失效、回退默认材质，
画面表现为「一整块纯白平面、且没有顶点位移」——看起来像 DEM 数据或流式加载出了问题，
和「着色器里多写了一个 return」这个真实原因毫无表面联系。

讽刺的是，这四行本身正是**为了排查光照问题而加的诊断代码**。
诊断代码把被诊断的东西弄坏了，且坏法与原症状相似。

### 抓这个报错的正确命令

v003 第七节给的命令方向对，但少了退出条件，主场景会一直跑不退出：

```bash
godot --headless --path . --quit-after 180 -- --region narati
```

headless 用的是 dummy 渲染后端，**照样会报着色器编译错误**（见上面的 `material_storage.cpp` 路径），
所以不需要开窗口就能抓到。

---

## 三、验证结果

| 检验 | 结果 |
|---|---|
| 着色器编译 | 通过，无 SHADER ERROR |
| DEM 回归自检 | **9/9 通过** |
| 八处地标截图（`--capture`） | 16 张全部正常，地形有起伏、山脊、雪线 |
| 19 个调试变体（`--variants`） | 全部生成，含此前根本跑不了的 4 档光照诊断 |
| 那拉提性能 | 134–158 fps / 80 draw call / 551 k 三角面 |

性能与 v003 第二节记录的基准（150 fps / 80 draw call / 551 k 面）一致，说明这次改动只影响编译、不影响渲染负载。

### 光照链诊断（此前被编译失败挡着，从未真正跑起来过）

`debug_mode` 5–8 这四档就是为 v003 第五节第 6 条那轮排查写的，现在终于能用了。
在那拉提同一像素上实测：

| 变体 | 含义 | 实测灰度 |
|---|---|---|
| `p_atten` | ATTENUATION（阴影） | 255（满） |
| `q_ndl` | N·L | 满 |
| `r_rampk` | ramp 输出 k | 255（满） |
| `s_lightcol` | LIGHT_COLOR / PI | 255（满） |
| `d_flat_color` | ALBEDO 固定 0.62 | 255（饱和） |

**四环全部为满值，光照管线本身正常。**

---

## 四、未解决：地表偏暗与草地不显示

修好编译只是让画面回到「能看」，**P3 的卡通渲染仍未完成**，两个问题留在这里：

### 1. 草地一株都没有

`client/render/grass.gd` 的 `GrassField` 被正常创建、`streamer.register(grass.material)` 也调用了，
三角面数（551 k）与 v003 记录一致，说明草的几何在场景里也提交了，但画面上完全看不到。

在离地 2 m 的那拉提截图上取任意三点，像素值**完全相同**（R27 G52 B9），
放大 3 倍后仍是一片均匀色——没有草，也没有 `albedo_variation` 应有的低频明度扰动。

**未定位。** 可能的方向：草的生长条件（`ok` 连乘项里某一项为 0）、
`height_scale`/`patch_bias` 被 `apply_env` 算成了 0、或高程窗口纹理未真正送到草的材质上
（那样 `ts_surface_height` 返回 0，草会掉到海平面，在 2228 m 的那拉提就是地下 2228 m）。
后者与 v003 第五节第 5 条是同一类问题，建议优先查。

### 2. 地表整体偏暗

那拉提地表实测 (27, 52, 9)。这个值本身**不构成 bug 判定**，因为它至少有三个合理来源叠加：

- `_apply_season_for` 里对地表基色**有意**做了 `darkened(0.30)`（`client/main.gd:250`），
  注释写明是为了让草地实例盖上去时有层次——而草现在没盖上去。
- 该点的实际 ALBEDO 未必等于 `color_grass`，分层配色会按坡度/高程 mix 到岩石或干草色。
- `tonemap_mode = 0`（LINEAR），没有色调映射参与，但环境光有 0.5 的贡献。

排查中我一度按「实测 52 接近 ALBEDO 被平方的理论值 48」推断二次相乘仍在，
**这个推断不成立**——它依赖「采样点的 ALBEDO 恰好是 color_grass」这一未经验证的假设，
而 `--variants` 模式的相机位置与 `--capture` 模式不同，该点可能落在被 mix 过的坡面上。
四环诊断已证明光照管线正常，所以 v003 第五节第 6 条那个修复**没有被推翻**，
但也**还没有被正面确认**——正面确认需要在同一相机位下逐项分离 ALBEDO 与光照，尚未做。

---

## 五、下一步

1. **查草地为什么不显示**（第四节第 1 条）。它挡着 P3 剩下的所有配色工作——
   地表基色是按「有草覆盖」压暗的，草不出来就没法评估配色。
2. 草的问题解决后，再回头正面确认 ALBEDO 二次相乘的修复效果。
3. P3 剩余项：天空 shader、水面、树木、描边、昼夜（v003 第三节）。
