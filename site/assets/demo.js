// 首页演示动画：边说边出字 → 逐个划掉口头禅 → 在光标处打出整理好的句子。只播放一次，最后停在整理好的画面。
// 页面源码里本来就是完整的文字（给搜索引擎和不运行脚本的访客看），这里只负责播放。
// 系统开启"减弱动态效果"时不播放，保持静态。
(() => {
  const demo = document.querySelector(".demo");
  if (!demo || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

  const said = demo.querySelector(".demo-said");
  const out = demo.querySelector(".demo-out");
  const typed = demo.querySelector(".demo-typed");
  const capsule = demo.querySelector(".capsule");
  if (!said || !out || !typed || !capsule) return;

  const label = said.querySelector(".demo-label");
  const pieces = [...said.childNodes]
    .filter((node) => node !== label)
    .map((node) => ({ node, text: node.textContent }));
  const fillers = [...said.querySelectorAll("del")];
  const result = typed.textContent;
  const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  // 固定两行的高度，逐字出现时页面不会跳动
  const lockHeights = () => {
    for (const row of [said, out]) {
      row.style.minHeight = "";
      row.style.minHeight = `${row.offsetHeight}px`;
    }
  };

  // 页面在后台或演示不在屏幕上时暂停，回来后接着播放
  let visible = true;
  new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; }).observe(demo);
  const whenVisible = async () => {
    while (!visible || document.hidden) await wait(300);
  };

  const typeInto = async (node, text, delay) => {
    for (const char of Array.from(text)) {
      await whenVisible();
      node.textContent += char;
      await wait(delay);
    }
  };

  const play = async () => {
    lockHeights();
    window.addEventListener("resize", () => {
      // 宽度变化时用完整文字重新量高度，再恢复播放到一半的文字
      const current = pieces.map((piece) => piece.node.textContent);
      const currentTyped = typed.textContent;
      pieces.forEach((piece) => { piece.node.textContent = piece.text; });
      typed.textContent = result;
      lockHeights();
      pieces.forEach((piece, index) => { piece.node.textContent = current[index]; });
      typed.textContent = currentTyped;
    });
    demo.classList.add("is-animated");

    pieces.forEach((piece) => { piece.node.textContent = ""; });
    typed.textContent = "";
    capsule.classList.add("is-listening");
    await wait(500);

    // 说话：识别到的文字逐字出现
    for (const piece of pieces) await typeInto(piece.node, piece.text, 55);
    await wait(350);
    capsule.classList.remove("is-listening");

    // 整理：逐个划掉口头禅
    await wait(300);
    for (const del of fillers) {
      await whenVisible();
      del.classList.add("struck");
      await wait(300);
    }

    // 粘贴：整理好的句子出现在光标处，之后停在这个画面
    await wait(350);
    await typeInto(typed, result, 38);
  };

  play();
})();
