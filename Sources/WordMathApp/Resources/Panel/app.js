(() => {
  'use strict';

  const byID = id => document.getElementById(id);
  const panel = byID('panel');
  const prompt = byID('prompt');
  const model = byID('model');
  const preview = byID('preview');
  const editValue = byID('editValue');
  const state = {
    draft: null, originalPrompt: '', mode: 'revision',
    activeNode: null, scopePath: null, pending: null, busy: false
  };
  const post = message => window.webkit.messageHandlers.wordmath.postMessage(message);
  let lastHeight = 0;
  let composing = false;
  let compositionEndedAt = -Infinity;

  function resizePanel() {
    const height = Math.ceil(panel.getBoundingClientRect().height);
    if (height !== lastHeight) {
      lastHeight = height;
      post({ action: 'resize', width: 620, height });
    }
  }

  function status(message = '', isError = false) {
    const line = byID('status');
    line.textContent = message;
    line.hidden = !message;
    line.classList.toggle('error', isError);
  }

  function controls() {
    const hasDraft = !!state.draft;
    const hasModels = model.options.length > 0;
    byID('setupHint').hidden = hasModels;
    model.hidden = !hasModels;
    byID('modeBar').hidden = byID('previewArea').hidden = !hasDraft;
    byID('generate').textContent = hasModels ? (hasDraft ? '更新预览' : '生成') : '配置服务';
    byID('generate').disabled = state.busy || (hasModels && !prompt.value.trim());
    byID('insert').disabled = !hasDraft || state.busy;
    model.disabled = prompt.disabled = state.busy;
    byID('revisionMode').disabled = byID('replaceMode').disabled = state.busy;
    byID('revisionMode').setAttribute('aria-pressed', String(state.mode === 'revision'));
    byID('replaceMode').setAttribute('aria-pressed', String(state.mode === 'replace'));
    prompt.placeholder = hasDraft
      ? (state.mode === 'revision' ? '描述要修改的地方…' : '重新描述所需内容…')
      : '描述符号、公式或推导…';
    byID('scope').hidden = !state.scopePath;
    byID('editBar').hidden = !state.activeNode || state.busy;
    panel.setAttribute('aria-busy', String(state.busy));
    resizePanel();
  }

  function setModels(models, preferredID) {
    const previous = model.value;
    model.replaceChildren();
    for (const entry of models || []) {
      const option = document.createElement('option');
      option.value = entry.id;
      option.textContent = entry.label;
      model.append(option);
    }
    const ids = Array.from(model.options, entry => entry.value);
    const selected = [previous, preferredID, ids[0]].find(value => ids.includes(value));
    if (selected !== undefined) model.value = selected;
    controls();
  }

  function clearSelection() {
    for (const item of preview.querySelectorAll('.selected')) item.classList.remove('selected');
    state.activeNode = null;
    state.scopePath = null;
    byID('scopeLabel').textContent = '';
  }

  function start(config = {}) {
    Object.assign(state, { draft: null, originalPrompt: '', mode: 'revision',
      activeNode: null, scopePath: null, pending: null, busy: false });
    model.replaceChildren();
    preview.replaceChildren();
    preview.style.removeProperty('--word-font-family');
    preview.style.removeProperty('--word-font-size');
    if (typeof config.fontName === 'string' && config.fontName.trim()) {
      preview.style.setProperty('--word-font-family', CSS.escape(config.fontName.trim()));
    }
    if (Number.isFinite(config.fontSize) && config.fontSize > 0 && config.fontSize <= 1638) {
      preview.style.setProperty('--word-font-size', config.fontSize + 'pt');
    }
    prompt.value = '';
    status();
    setModels(config.models, config.defaultModelID);
    prompt.focus();
  }

  // Copy only the formatting vocabulary emitted by the native preview renderer.
  // Provider strings always enter the live DOM as text, never as executable markup.
  const htmlTags = new Set(['p', 'span', 'div', 'table', 'tbody', 'tr', 'td']);
  const mathTags = new Set(('math mrow mi mn mo mtext mfrac msub msup msubsup mroot msqrt ' +
    'munder mover munderover mtable mtr mtd').split(' '));
  const mathAttrs = ['display', 'accent', 'fence', 'stretchy', 'columnalign', 'movablelimits', 'mathvariant'];
  const mathNS = 'http://www.w3.org/1998/Math/MathML';

  function copyFormattedNode(source) {
    if (source.nodeType === Node.TEXT_NODE) return document.createTextNode(source.textContent);
    if (source.nodeType !== Node.ELEMENT_NODE) return null;
    const tag = source.localName;
    const isMath = source.namespaceURI === mathNS && mathTags.has(tag);
    if (!isMath && !(source.namespaceURI === 'http://www.w3.org/1999/xhtml' && htmlTags.has(tag))) return null;
    const output = isMath ? document.createElementNS(mathNS, tag) : document.createElement(tag);
    for (const key of isMath ? ['data-path', 'data-edit', ...mathAttrs] : ['data-path', 'data-edit']) {
      if (source.hasAttribute(key)) output.setAttribute(key, source.getAttribute(key));
    }
    if (source.classList.contains('equation')) output.classList.add('equation');
    for (const child of source.childNodes) {
      const copied = copyFormattedNode(child);
      if (copied) output.appendChild(copied);
    }
    return output;
  }

  function render(html) {
    const source = new DOMParser().parseFromString(html, 'text/html');
    preview.replaceChildren();
    for (const node of source.body.childNodes) {
      const result = copyFormattedNode(node);
      if (result) preview.appendChild(result);
    }
  }

  function result(draft, html) {
    if (typeof draft === 'string') draft = JSON.parse(draft);
    if (!draft || !Array.isArray(draft.blocks) || typeof html !== 'string') {
      error('无法显示排版预览，请重试。');
      return;
    }
    if (state.pending && state.pending.mode !== 'revision') {
      state.originalPrompt = state.pending.input;
    }
    state.draft = draft;
    state.mode = 'revision';
    state.pending = null;
    state.busy = false;
    clearSelection();
    render(html);
    prompt.value = '';
    status();
    controls();
    prompt.focus();
  }

  function error(message) {
    state.busy = false;
    state.pending = null;
    status(String(message), true);
    controls();
    prompt.focus();
  }

  function busy(value) {
    state.busy = Boolean(value);
    if (!value && !byID('status').classList.contains('error')) status();
    controls();
  }

  function resolveLeaf(pointer) {
    const keys = pointer.split('/').slice(1).map(key => key.replace(/~1/g, '/').replace(/~0/g, '~'));
    let parent = state.draft;
    for (const key of keys.slice(0, -1)) {
      if (!parent || !Object.hasOwn(parent, key)) return null;
      parent = parent[key];
    }
    const key = keys[keys.length - 1];
    if (!parent || !Object.hasOwn(parent, key) || typeof parent[key] !== 'string') return null;
    return { parent, key };
  }

  function applyEdit() {
    if (!state.activeNode) return true;
    const target = resolveLeaf(state.activeNode.getAttribute('data-path'));
    if (!target) return false;
    const value = editValue.value;
    if (!value.length) {
      status('请输入修改后的文字或符号。若要删除这一项，可针对选区追问。', true);
      editValue.focus();
      return false;
    }
    target.parent[target.key] = value;
    state.activeNode.textContent = value;
    return true;
  }

  function activate(element, edit) {
    if (!element || state.busy || (state.activeNode && !applyEdit())) return;
    clearSelection();
    const path = element.getAttribute('data-path');
    if (!path) return;
    state.scopePath = path;
    element.classList.add('selected');
    byID('scopeLabel').textContent = '选区 · ' + (element.textContent || '公式').slice(0, 28);
    state.mode = 'revision';
    const target = element.hasAttribute('data-edit') && resolveLeaf(path);
    if (edit && target) {
      state.activeNode = element;
      editValue.value = target.parent[target.key];
    }
    controls();
    if (state.activeNode) {
      editValue.focus();
      editValue.select();
    } else if (edit) {
      prompt.focus();
    }
  }

  function finishEdit(follow) {
    if (!applyEdit()) return;
    const node = state.activeNode;
    if (!follow) clearSelection();
    else {
      state.activeNode = null;
      byID('scopeLabel').textContent = '选区 · ' + (node?.textContent || '公式').slice(0, 28);
    }
    status();
    controls();
    prompt.focus();
  }

  function setMode(mode) {
    if (state.busy || state.mode === mode || !applyEdit()) return;
    clearSelection();
    state.mode = mode;
    prompt.value = mode === 'replace' ? state.originalPrompt : '';
    status();
    controls();
    prompt.focus();
    if (mode === 'replace') prompt.select();
  }

  function generate() {
    if (state.busy) return;
    if (!model.options.length) { post({ action: 'settings' }); return; }
    const input = prompt.value.trim();
    if (!input || !applyEdit()) return;
    const isRevision = !!state.draft && state.mode === 'revision';
    const scope = isRevision && state.scopePath;
    const instruction = scope ? input + '\n本次重点修改当前预览中 JSON Pointer 为 ' + scope + ' 的选区。' : input;
    state.pending = { mode: isRevision ? 'revision' : 'new', input };
    status(isRevision ? '正在更新预览…' : '正在生成预览…');
    busy(true);
    post({ action: 'generate', prompt: instruction, modelID: model.value,
      originalPrompt: isRevision ? state.originalPrompt : input,
      document: isRevision ? state.draft : null, selectionPath: scope || null });
  }

  function insert() {
    if (!state.draft || state.busy || !applyEdit()) return;
    status('正在插入 Word…');
    busy(true);
    post({ action: 'insert', document: state.draft });
  }

  // Enter also confirms a Chinese IME candidate. Leave the native composition
  // event untouched and ignore its implicit form submission.
  document.addEventListener('compositionstart', () => { composing = true; });
  document.addEventListener('compositionend', () => {
    composing = false;
    compositionEndedAt = performance.now();
  });
  const finishingComposition = () => composing || performance.now() - compositionEndedAt < 40;
  byID('promptForm').addEventListener('submit', event => {
    event.preventDefault();
    if (!finishingComposition()) generate();
  });
  prompt.addEventListener('input', controls);
  byID('settings').addEventListener('click', () => post({ action: 'settings' }));
  byID('cancel').addEventListener('click', () => post({ action: 'cancel' }));
  byID('insert').addEventListener('click', insert);
  byID('replaceMode').addEventListener('click', () => setMode('replace'));
  byID('revisionMode').addEventListener('click', () => setMode('revision'));
  byID('clearScope').addEventListener('click', () => finishEdit(false));
  byID('applyEdit').addEventListener('click', () => finishEdit(false));
  byID('followSelection').addEventListener('click', () => finishEdit(true));
  preview.addEventListener('click', event => activate(event.target.closest('[data-path]'), true));

  preview.addEventListener('keydown', event => {
    if (event.metaKey || state.busy) return;
    const leaves = Array.from(preview.querySelectorAll('[data-edit]'));
    if (!leaves.length) return;
    const current = leaves.indexOf(preview.querySelector('.selected'));
    if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
      event.preventDefault();
      const next = event.key === 'ArrowLeft' ? Math.max(0, current - 1) : Math.min(leaves.length - 1, current + 1);
      activate(leaves[next], false);
      leaves[next].scrollIntoView({ block: 'nearest' });
    } else if (event.key === 'Enter') {
      event.preventDefault();
      activate(leaves[Math.max(0, current)], true);
    }
  });

  document.addEventListener('keydown', event => {
    if (event.isComposing || event.keyCode === 229 || finishingComposition()) return;
    if (event.metaKey && event.key === 'Enter') { event.preventDefault(); insert(); }
    else if (event.key === 'Escape') {
      event.preventDefault();
      if (state.activeNode && document.activeElement === editValue) {
        clearSelection(); controls(); prompt.focus();
      } else post({ action: 'cancel' });
    } else if (event.key === 'Enter' && document.activeElement === editValue) {
      event.preventDefault(); finishEdit(false);
    }
  });
  new ResizeObserver(resizePanel).observe(panel);
  window.WordMath = Object.freeze({ start, result, error, busy, setModels });
})();
