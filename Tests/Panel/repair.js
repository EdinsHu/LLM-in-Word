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

  WordMath.start({ models: [{ id: 'a', label: 'A' }, { id: 'b', label: 'B' }] });
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
  WordMath.formatError('请求失败，可重试');
  $('repair').click();
  const draft = { blocks: [{ type: 'paragraph', inlines: [{ text: '矩阵' }] }] };
  const html = '<p><span data-edit="text" data-path="/blocks/0/inlines/0/text">矩阵</span></p>';
  WordMath.receipt('模型 A · 请求 ID 456');
  WordMath.result(draft, html);
  assert(!$('receipt').hidden, 'A successful preview must retain its provider receipt.');
  generate('再加一列');
  assert($('receipt').hidden, 'New generation must not display an old API receipt.');
  assert(calls('generate').at(-1).originalPrompt === '插入矩阵', 'A repaired draft must retain the original instruction.');
  assert(calls('generate').at(-1).document.blocks[0].inlines[0].text === '矩阵', 'The follow-up must include the repaired draft.');

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
  assert(!calls('insert').length, 'Repair must never insert the preview into Word.');
  return 'PASS';
})();
