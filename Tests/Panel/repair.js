// Run via: swift Tests/Panel/run.swift
(() => {
  const $ = id => document.getElementById(id);
  const events = [];
  window.webkit = { messageHandlers: { wordmath: {
    postMessage: message => events.push(structuredClone(message))
  } } };
  const calls = action => events.filter(event => event.action === action);
  function assert(condition, message) {
    if (!condition) throw new Error(message);
  }
  function generate(instruction) {
    $('prompt').value = instruction;
    $('promptForm').requestSubmit();
  }
  function assertClearOfGrip(ids) {
    for (const id of ids) {
      const rect = $(id).getBoundingClientRect();
      assert(rect.width > 0 && rect.height > 0, id + ' must be visible.');
      // The native grip covers the first 22 x 44 points at the top left.
      assert(rect.left >= 22 || rect.top >= 44, id + ' overlaps the native drag grip.');
    }
  }

  WordMath.start({ models: [{ id: 'a', label: 'A' }, { id: 'b', label: 'B' }] });
  const promptControls = ['prompt', 'model', 'settings', 'generate'];
  assertClearOfGrip(promptControls);
  generate('插入矩阵');
  assert($('receipt').hidden, 'Local requests must not manufacture an API receipt.');
  WordMath.receipt('模型 A · 请求 ID 123');
  WordMath.formatError('格式错误');
  assert(!$('receipt').hidden && $('receipt').textContent.includes('123'), 'A real provider receipt must survive a parse failure.');
  assert(!$('repairBar').hidden && !calls('repair').length, 'A format error must offer repair without contacting the model.');
  $('repair').click();
  $('repair').click();
  assert($('receipt').hidden, 'A repair request must clear the previous receipt.');
  assert(calls('repair').length === 1, 'Repeated clicks during a request must send only one call.');
  WordMath.receipt('模型 A · 请求 ID 234');
  WordMath.formatError('第 7 个内容块：格式错误');
  assert($('status').textContent.includes('修复排版未完成') && $('status').textContent.includes('第 7 个内容块'),
    'A failed repair must show both the failed operation and its latest diagnostic.');
  assert(!$('repairBar').hidden && calls('repair').length === 1 &&
    $('receipt').textContent.includes('234'), 'A second failure should only offer a user-triggered retry with its own receipt.');
  $('repair').click();
  assert(calls('repair').length === 2 && $('receipt').hidden, 'Retry must send one new request and clear the receipt.');
  const draft = { blocks: [{ type: 'paragraph', inlines: [{ text: '矩阵' }, { math: { symbol: 'A' } }] }] };
  const html = '<p><span data-edit="text" data-path="/blocks/0/inlines/0/text">矩阵</span>' +
    '<math><mi data-edit="symbol" data-path="/blocks/0/inlines/1/math/symbol">A</mi></math></p>';
  WordMath.receipt('模型 A · 请求 ID 456');
  WordMath.result(draft, html);
  assertClearOfGrip([...promptControls, 'revisionMode', 'replaceMode']);
  const symbol = $('preview').querySelector('mi');
  symbol.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  const editor = $('editValue');
  assert(!$('editBar').hidden && editor.value.slice(editor.selectionStart, editor.selectionEnd) === 'A',
    'Clicking a formula must still select its symbol for editing.');
  editor.setRangeText('B');
  $('applyEdit').click();
  assert(symbol.textContent === 'B', 'Applying a local formula edit must update the preview.');
  assert(!$('receipt').hidden, 'A successful preview must retain its provider receipt.');
  generate('再加一列');
  assert($('receipt').hidden, 'New generation must not display an old API receipt.');
  assert(calls('generate').at(-1).originalPrompt === '插入矩阵', 'A repaired draft must retain the original instruction.');
  assert(calls('generate').at(-1).document.blocks[0].inlines[0].text === '矩阵', 'The follow-up must include the repaired draft.');
  assert(calls('generate').at(-1).document.blocks[0].inlines[1].math.symbol === 'B', 'The follow-up must retain the local formula edit.');

  WordMath.formatError('格式错误');
  $('model').value = 'b';
  $('model').dispatchEvent(new Event('change'));
  assert(calls('discardRepair').length === 1 && $('repairBar').hidden, 'Changing models must discard the stale answer.');
  $('repair').click();
  assert(calls('repair').length === 2, 'A hidden stale repair cannot send a request.');

  generate('更新内容');
  WordMath.formatError('格式错误');
  $('prompt').value = '其他要求';
  $('prompt').dispatchEvent(new Event('input'));
  $('prompt').dispatchEvent(new Event('input'));
  assert(calls('discardRepair').length === 2, 'Typing after an error must release the retained answer exactly once.');

  generate('更新内容');
  WordMath.formatError('格式错误');
  $('preview').querySelector('span').click();
  assert(calls('discardRepair').length === 3 && $('repairBar').hidden, 'Editing the preview must invalidate the repair.');
  generate('只修改系数');
  // The status menu can change the available models even during a request.
  WordMath.setModels([{ id: 'a', label: 'A' }], 'a');
  WordMath.formatError('先前模型的回复格式错误');
  assert(calls('discardRepair').length === 4 && $('repairBar').hidden,
    'A format failure arriving after an in-flight model change must discard the newly retained native reply.');
  $('repair').click();
  assert(calls('repair').length === 2, 'Changing model during a request must not enable a repair on the previous account.');
  assert(!calls('insert').length, 'Repair must never insert the preview into Word.');
  const beforeLogin = calls('generate').length;
  WordMath.start();
  const picker = $('model');
  assert(!picker.hidden && picker.options.length === 2, 'Account login must be reachable before any model is configured.');
  picker.value = picker.options[picker.options.length - 1].value;
  picker.dispatchEvent(new Event('change'));
  assert(calls('chatGPTSettings').length === 1 && picker.value === '' &&
    calls('generate').length === beforeLogin, 'Opening sign-in must not send a model request.');
  const plan = { id: 'plan1', label: 'From account', usesChatGPTPlan: true };
  const api = { id: 'api1', label: 'From API' };
  WordMath.setModels([plan, api], 'plan1');
  assert(picker.value === 'plan1' && !$('planUsage').hidden, 'Plan selection must show where usage is charged.');
  $('manageUsage').click();
  assert(calls('chatGPTUsage').length === 1, 'The plan usage link must reach the native host.');
  WordMath.setModels([api], 'unavailable:plan1');
  generate('保留原来的计费用途');
  assert(!picker.value && calls('generate').length === beforeLogin,
    'An unavailable plan must not send the prompt using a different account.');
  picker.value = 'api1';
  picker.dispatchEvent(new Event('change'));
  generate('显式选择 API');
  assert($('planUsage').hidden && calls('generate').at(-1).modelID === 'api1', 'An explicit account change should work.');
  return 'PASS';
})();
