// 首页"AI 服务"那一栏的标签切换：Ollama / LM Studio / 云端。
// 符合 WAI-ARIA 标签页的用法：点击或用左右方向键切换，Home/End 跳到第一个和最后一个。
// 不运行脚本时只显示第一个标签的截图。
(() => {
  for (const list of document.querySelectorAll('[role="tablist"]')) {
    const tabs = [...list.querySelectorAll('[role="tab"]')];
    const select = (tab, focus) => {
      for (const other of tabs) {
        const selected = other === tab;
        other.setAttribute("aria-selected", String(selected));
        other.tabIndex = selected ? 0 : -1;
        document.getElementById(other.getAttribute("aria-controls")).hidden = !selected;
      }
      if (focus) tab.focus();
    };
    // 鼠标移到标签上或键盘聚焦时，先把其他标签的截图下载好，点下去就不会空白
    const preload = () => {
      for (const tab of tabs) {
        for (const img of document.getElementById(tab.getAttribute("aria-controls")).querySelectorAll("img")) {
          img.loading = "eager";
        }
      }
    };
    list.addEventListener("pointerenter", preload, { once: true });
    list.addEventListener("focusin", preload, { once: true });

    tabs.forEach((tab, index) => {
      tab.addEventListener("click", () => select(tab, false));
      tab.addEventListener("keydown", (event) => {
        const next = {
          ArrowRight: tabs[(index + 1) % tabs.length],
          ArrowLeft: tabs[(index - 1 + tabs.length) % tabs.length],
          Home: tabs[0],
          End: tabs[tabs.length - 1],
        }[event.key];
        if (next) {
          event.preventDefault();
          select(next, true);
        }
      });
    });
  }
})();
