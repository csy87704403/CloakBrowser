#!/usr/bin/env python3
"""CloakBrowser Linux VPS 优化启动器

目标：在低内存 Linux VPS 上以「有头 + Windows 指纹 + 省内存」模式运行 CloakBrowser

特性：
  - 自动启动 Xvfb 虚拟显示（小屏幕 + 低色深，省内存）
  - headless=False（真有头，反检测效果好）
  - Linux 上默认 --fingerprint-platform=windows（CloakBrowser 已内置）
  - 内存优化参数：禁用 GPU、限制 JS 堆、拦截图片/媒体/字体
  - 单 Browser + 多 Context 复用，用完即关，防内存泄漏
  - 可选代理 + geoip 自动匹配时区

用法：
  # 基础用法（无代理）
  python low_memory_launcher.py --url https://example.com

  # 带代理（推荐，geoip 自动匹配时区/语言）
  python low_memory_launcher.py --proxy http://user:pass@proxy:8080 --url https://example.com

  # 批量访问多个 URL
  python low_memory_launcher.py --urls urls.txt

  # 不拦截图片（需要看完整页面时）
  python low_memory_launcher.py --no-block-images --url https://example.com

  # 自定义 Xvfb 分辨率
  python low_memory_launcher.py --xvfb-resolution 1280x720x8 --url https://example.com
"""

from __future__ import annotations

import argparse
import logging
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("cloak-launcher")


# ---------------------------------------------------------------------------
# Xvfb 管理
# ---------------------------------------------------------------------------

XVFB_PROCESS = None


def start_xvfb(display: str = ":99", resolution: str = "1280x800x8") -> None:
    """启动 Xvfb 虚拟显示服务器。

    默认 1280x800x8（8 位色深），比 Docker 默认的 1920x1080x24 省约 60% 显存。
    """
    global XVFB_PROCESS

    # 清理残留锁文件
    display_num = display.replace(":", "")
    lock_file = f"/tmp/.X{display_num}-lock"
    socket_dir = f"/tmp/.X11-unix"
    if os.path.exists(lock_file):
        os.remove(lock_file)
        logger.info("清理残留 Xvfb 锁文件: %s", lock_file)

    width, height, depth = resolution.split("x")

    cmd = [
        "Xvfb",
        display,
        "-screen", "0", resolution,
        "-ac",
        "-nolisten", "tcp",
    ]

    logger.info("启动 Xvfb: %s (分辨率 %s)", display, resolution)
    XVFB_PROCESS = subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    # 等待 Xvfb 就绪
    time.sleep(1)
    if XVFB_PROCESS.poll() is not None:
        logger.error("Xvfb 启动失败，退出码: %d", XVFB_PROCESS.returncode)
        sys.exit(1)

    os.environ["DISPLAY"] = display
    logger.info("Xvfb 已启动 (PID: %d)", XVFB_PROCESS.pid)


def stop_xvfb() -> None:
    """停止 Xvfb 进程。"""
    global XVFB_PROCESS
    if XVFB_PROCESS and XVFB_PROCESS.poll() is None:
        XVFB_PROCESS.terminate()
        try:
            XVFB_PROCESS.wait(timeout=5)
        except subprocess.TimeoutExpired:
            XVFB_PROCESS.kill()
        logger.info("Xvfb 已停止")


# ---------------------------------------------------------------------------
# 资源拦截（省内存核心）
# ---------------------------------------------------------------------------

def setup_resource_blocking(page, block_images: bool = True, block_fonts: bool = True, block_media: bool = True) -> None:
    """拦截不需要的资源类型，大幅减少内存占用。

    图片/字体/媒体通常占页面内存的 60%+，对于 Agent 只需要 DOM/文本的场景，
    拦截后内存可降到原来的 30-50%。
    """
    blocked_types = set()
    if block_images:
        blocked_types.add("image")
    if block_fonts:
        blocked_types.add("font")
    if block_media:
        blocked_types.add("media")

    if not blocked_types:
        return

    def handle_route(route):
        if route.request.resource_type in blocked_types:
            route.abort()
        else:
            route.continue_()

    page.route("**/*", handle_route)
    logger.info("资源拦截已启用: %s", ", ".join(sorted(blocked_types)))


# ---------------------------------------------------------------------------
# 内存优化参数
# ---------------------------------------------------------------------------

def get_memory_saving_args() -> list[str]:
    """返回省内存的 Chromium 启动参数。

    这些参数配合 CloakBrowser 自带的 stealth args 使用，
    不会覆盖指纹相关的参数（build_args 会做去重）。
    """
    return [
        # GPU 相关 - 在 Xvfb 下不需要真实 GPU
        "--disable-gpu",
        "--disable-software-rasterizer",

        # 内存管理
        "--disable-dev-shm-usage",          # 避免 /dev/shm 空间不足
        "--js-flags=--max-old-space-size=512",  # 限制 V8 堆上限

        # 禁用不需要的功能
        "--mute-audio",
        "--hide-scrollbars",
        "--disable-background-timer-throttling",
        "--disable-renderer-backgrounding",
        "--disable-backgrounding-occluded-windows",
        "--disable-features=TranslateUI,MediaRouter,ChromeOptimizationHints",

        # 渲染优化
        "--blink-settings=imagesEnabled=false",  # 二次保险：即使没拦截也尽量不加载图片
    ]


# ---------------------------------------------------------------------------
# 核心启动逻辑
# ---------------------------------------------------------------------------

def launch_browser(
    proxy: str | None = None,
    timezone: str | None = None,
    locale: str | None = None,
    geoip: bool = False,
    humanize: bool = True,
    extra_args: list[str] | None = None,
):
    """启动 CloakBrowser，返回 Browser 对象。

    在 Linux 上，CloakBrowser 默认已加 --fingerprint-platform=windows，
    所以不需要手动指定。
    """
    # 延迟导入，确保可以设置 PYTHONPATH 后再导入
    from cloakbrowser import launch

    all_args = get_memory_saving_args()
    if extra_args:
        all_args.extend(extra_args)

    launch_kwargs = {
        "headless": False,       # 有头模式，反检测效果最好
        "humanize": humanize,    # 人类化鼠标/键盘行为
        "args": all_args,
        "stealth_args": True,    # 使用默认 stealth 参数（含 --fingerprint-platform=windows）
    }

    if proxy:
        launch_kwargs["proxy"] = proxy
    if timezone:
        launch_kwargs["timezone"] = timezone
    if locale:
        launch_kwargs["locale"] = locale
    if geoip and proxy:
        launch_kwargs["geoip"] = True

    logger.info("启动 CloakBrowser (headless=False, humanize=%s, proxy=%s)",
                humanize, proxy or "无")

    browser = launch(**launch_kwargs)
    logger.info("CloakBrowser 已启动")
    return browser


# ---------------------------------------------------------------------------
# 页面访问（带内存管理）
# ---------------------------------------------------------------------------

def visit_page(
    browser,
    url: str,
    block_images: bool = True,
    block_fonts: bool = True,
    block_media: bool = True,
    timeout: int = 30000,
) -> dict:
    """访问单个页面，返回提取的信息。

    使用 context 模式：每个页面用独立 context，用完立即关闭，防止内存泄漏。
    """
    context = browser.new_context()
    page = context.new_page()

    # 设置资源拦截
    setup_resource_blocking(page, block_images=block_images, block_fonts=block_fonts, block_media=block_media)

    try:
        logger.info("访问: %s", url)
        page.goto(url, timeout=timeout, wait_until="domcontentloaded")

        # 提取基本信息
        result = {
            "url": page.url,
            "title": page.title(),
            "status": "ok",
        }

        logger.info("  标题: %s", result["title"])
        return result

    except Exception as e:
        logger.error("  访问失败: %s", e)
        return {"url": url, "title": "", "status": f"error: {e}"}

    finally:
        page.close()
        context.close()
        logger.info("  页面已关闭，内存已回收")


def visit_pages_batch(
    browser,
    urls: list[str],
    block_images: bool = True,
    block_fonts: bool = True,
    block_media: bool = True,
    context_recycle_interval: int = 10,
    timeout: int = 30000,
) -> list[dict]:
    """批量访问多个 URL。

    使用单 Browser + 多 Context 模式，每 N 个页面重建 context 防止内存累积。
    """
    results = []
    context = browser.new_context()
    page_count = 0

    for url in urls:
        page = context.new_page()
        setup_resource_blocking(page, block_images=block_images, block_fonts=block_fonts, block_media=block_media)

        try:
            logger.info("[%d/%d] 访问: %s", page_count + 1, len(urls), url)
            page.goto(url, timeout=timeout, wait_until="domcontentloaded")

            result = {
                "url": page.url,
                "title": page.title(),
                "status": "ok",
            }
            logger.info("  标题: %s", result["title"])
            results.append(result)

        except Exception as e:
            logger.error("  失败: %s", e)
            results.append({"url": url, "title": "", "status": f"error: {e}"})

        finally:
            page.close()
            page_count += 1

            # 定期重建 context，清理内存
            if page_count % context_recycle_interval == 0:
                context.close()
                context = browser.new_context()
                logger.info("  Context 已重建（每 %d 页回收一次）", context_recycle_interval)

    context.close()
    return results


# ---------------------------------------------------------------------------
# 指纹验证
# ---------------------------------------------------------------------------

def verify_fingerprint(browser) -> None:
    """验证浏览器指纹是否伪装为 Windows。"""
    context = browser.new_context()
    page = context.new_page()

    try:
        page.goto("https://httpbin.org/headers", timeout=15000)
        info = page.evaluate("""() => {
            const gl = document.createElement('canvas').getContext('webgl');
            const dbg = gl ? gl.getExtension('WEBGL_debug_renderer_info') : null;
            return {
                platform: navigator.platform,
                userAgent: navigator.userAgent.substring(0, 80) + '...',
                gpu: dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : 'N/A',
                gpuVendor: dbg ? gl.getParameter(dbg.UNMASKED_VENDOR_WEBGL) : 'N/A',
                cores: navigator.hardwareConcurrency,
                memory: navigator.deviceMemory,
            };
        }""")

        logger.info("=== 指纹验证 ===")
        logger.info("  Platform: %s", info["platform"])
        logger.info("  UA: %s", info["userAgent"])
        logger.info("  GPU: %s — %s", info["gpuVendor"], info["gpu"])
        logger.info("  Cores: %s | Memory: %s GB", info["cores"], info["memory"])

        if info["platform"] == "Win32":
            logger.info("  Windows 指纹伪装: 成功")
        else:
            logger.warning("  Windows 指纹伪装: 失败 (platform=%s)", info["platform"])

    except Exception as e:
        logger.error("指纹验证失败: %s", e)

    finally:
        page.close()
        context.close()


# ---------------------------------------------------------------------------
# CLI 入口
# ---------------------------------------------------------------------------

def parse_args():
    parser = argparse.ArgumentParser(
        description="CloakBrowser Linux VPS 低内存启动器",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )

    # URL 参数
    parser.add_argument("--url", help="单个 URL")
    parser.add_argument("--urls", help="URL 列表文件（每行一个 URL）")

    # 代理
    parser.add_argument("--proxy", help="代理地址 (http://user:pass@host:port)")
    parser.add_argument("--geoip", action="store_true", help="根据代理 IP 自动匹配时区/语言")

    # 时区/语言
    parser.add_argument("--timezone", default="America/New_York", help="IANA 时区 (默认 America/New_York)")
    parser.add_argument("--locale", default="en-US", help="BCP 47 语言 (默认 en-US)")

    # Xvfb
    parser.add_argument("--xvfb-display", default=":99", help="Xvfb 显示号 (默认 :99)")
    parser.add_argument("--xvfb-resolution", default="1280x800x8", help="Xvfb 分辨率 (默认 1280x800x8)")
    parser.add_argument("--no-xvfb", action="store_true", help="不启动 Xvfb（已有 DISPLAY 环境变量时使用）")

    # 资源拦截
    parser.add_argument("--no-block-images", action="store_true", help="不拦截图片")
    parser.add_argument("--no-block-fonts", action="store_true", help="不拦截字体")
    parser.add_argument("--no-block-media", action="store_true", help="不拦截媒体")

    # 行为
    parser.add_argument("--no-humanize", action="store_true", help="禁用人类化行为（省 CPU）")
    parser.add_argument("--verify", action="store_true", help="启动后验证指纹")

    # 内存管理
    parser.add_argument("--context-recycle", type=int, default=10, help="每 N 个页面重建 context (默认 10)")
    parser.add_argument("--timeout", type=int, default=30000, help="页面加载超时 (毫秒，默认 30000)")

    return parser.parse_args()


def main():
    args = parse_args()

    # 收集要访问的 URL
    urls = []
    if args.url:
        urls.append(args.url)
    if args.urls:
        with open(args.urls, "r", encoding="utf-8") as f:
            urls.extend(line.strip() for line in f if line.strip() and not line.startswith("#"))

    if not urls and not args.verify:
        logger.error("请指定 --url 或 --urls")
        sys.exit(1)

    # 注册信号处理，确保退出时清理
    def cleanup(signum=None, frame=None):
        logger.info("正在清理...")
        stop_xvfb()
        sys.exit(0)

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    try:
        # 1. 启动 Xvfb
        if not args.no_xvfb:
            start_xvfb(display=args.xvfb_display, resolution=args.xvfb_resolution)
        else:
            if "DISPLAY" not in os.environ:
                logger.error("--no-xvfb 但未设置 DISPLAY 环境变量")
                sys.exit(1)
            logger.info("使用已有 DISPLAY=%s", os.environ["DISPLAY"])

        # 2. 启动 CloakBrowser
        browser = launch_browser(
            proxy=args.proxy,
            timezone=args.timezone,
            locale=args.locale,
            geoip=args.geoip,
            humanize=not args.no_humanize,
        )

        # 3. 可选：验证指纹
        if args.verify:
            verify_fingerprint(browser)

        # 4. 访问页面
        if len(urls) == 1:
            result = visit_page(
                browser,
                urls[0],
                block_images=not args.no_block_images,
                block_fonts=not args.no_block_fonts,
                block_media=not args.no_block_media,
                timeout=args.timeout,
            )
            logger.info("结果: %s", result)
        else:
            results = visit_pages_batch(
                browser,
                urls,
                block_images=not args.no_block_images,
                block_fonts=not args.no_block_fonts,
                block_media=not args.no_block_media,
                context_recycle_interval=args.context_recycle,
                timeout=args.timeout,
            )
            logger.info("完成 %d/%d 个页面", sum(1 for r in results if r["status"] == "ok"), len(results))

        # 5. 关闭浏览器
        browser.close()
        logger.info("浏览器已关闭")

    except Exception as e:
        logger.error("运行出错: %s", e, exc_info=True)
        sys.exit(1)

    finally:
        stop_xvfb()


if __name__ == "__main__":
    main()
