(() => {
  const words = {
    'This device':'Это устройство','This PC':'Этот ПК','This Mac':'Этот Mac',
    'Looking for nearby devices':'Поиск устройств поблизости',
    'Open Hop on another computer on the same Wi‑Fi network.':'Откройте Hop на другом устройстве в той же сети Wi-Fi.',
    'Drag files onto a device to send them':'Перетащите файлы на устройство',
    'Or click a device to choose files.':'Или нажмите на устройство, чтобы выбрать файлы.',
    'Saving to':'Сохранять в','Change…':'Изменить…','Click to rename':'Нажмите, чтобы переименовать',
    'Sent':'Отправлено','Received':'Получено','Declined':'Отклонено','Failed':'Ошибка','Waiting…':'Ожидание…',
    'Sending':'Отправка','Receiving':'Получение','No devices nearby':'Нет устройств поблизости',
    'Drop onto a device':'Перетащите на устройство','Drop the files right onto a device.':'Перетащите файлы прямо на устройство.',
    'There are no devices nearby yet.':'Пока нет устройств поблизости.','Wait for the current transfer to finish.':'Дождитесь завершения текущей передачи.',
    'Always accept from this device':'Всегда принимать от этого устройства','Decline':'Отклонить','Accept':'Принять',
    'Done':'Готово','Show in Finder':'Показать в Finder','Show in Folder':'Показать в папке',
    'Automatic':'Системная','Light':'Светлая','Dark':'Тёмная','Appearance':'Оформление',
    'Sharing stopped':'Обмен остановлен','Tap the Hop logo to start sharing.':'Нажмите на логотип Hop, чтобы включить обмен.',
    'Device is no longer online':'Устройство больше не в сети','Choose files again':'Выберите файлы заново',
    'Hop is stopped':'Обмен остановлен','No files selected':'Файлы не выбраны','Wait for the current transfer':'Дождитесь завершения текущей передачи',
    'Sender stopped responding':'Отправитель перестал отвечать','Cancelled by sender':'Отменено отправителем',
    'Receiver busy':'Устройство занято','Connection refused':'Соединение отклонено','Connection timed out':'Время ожидания соединения истекло',
    'timeout':'Время ожидания истекло','Failed to fetch':'Не удалось установить соединение',
  };
  const pluralRu = (n, forms) => forms[n % 100 >= 11 && n % 100 <= 14 ? 2 : n % 10 === 1 ? 0 : n % 10 >= 2 && n % 10 <= 4 ? 1 : 2];
  function translate(value, language='ru') {
    if (language !== 'ru') return value;
    if (Object.prototype.hasOwnProperty.call(words,value)) return words[value];
    let m;
    if ((m=value.match(/^Received from (.*)$/s))) return `Получено от ${m[1]}`;
    if ((m=value.match(/^Receiving from (.*)$/s))) return `Получение от ${m[1]}`;
    if ((m=value.match(/^(.*) would like to share$/s))) return `${m[1]} хочет отправить файлы`;
    if ((m=value.match(/^Release to send to (.*)$/s))) return `Отпустите, чтобы отправить на ${m[1]}`;
    if ((m=value.match(/^The transfer from (.*) was interrupted\.$/s))) return `Передача от ${m[1]} прервана.`;
    if ((m=value.match(/^Couldn’t send: (.*)$/s))) return `Не удалось отправить: ${translate(m[1],language)}`;
    if ((m=value.match(/^Forget (\d+) trusted devices?$/))) return `Забыть ${m[1]} ${pluralRu(+m[1],['доверенное устройство','доверенных устройства','доверенных устройств'])}`;
    if ((m=value.match(/^(\d+) more$/))) return `Ещё ${m[1]}`;
    if ((m=value.match(/^(Sending|Receiving) · (\d+)%$/))) return `${translate(m[1],language)} · ${m[2]}%`;
    if ((m=value.match(/^(\d+) files?(.*)$/s))) return `${m[1]} ${pluralRu(+m[1],['файл','файла','файлов'])}${m[2]}`;
    if ((m=value.match(/^(.*) of (.*) · (\d+)%$/))) return `${m[1]} из ${m[2]} · ${m[3]}%`;
    return value;
  }
  if (typeof module !== 'undefined') module.exports={translate,pluralRu};
  if (typeof document === 'undefined') return;
  let language='ru';
  const originals=new WeakMap();
  // Only application-owned labels are translated. Device names, filenames, paths,
  // editable fields and file chips are deliberately outside these bindings.
  const labels='.hint-title,.hint-sub,.status,.sheet-title,.check,.actions .btn,.toast,.me-caption,.footer-label,#changeDir,#forgetTrusted,#dropLabel,.sheet-sub[data-localize],.more-count';
  function bind(node, attribute) {
    const value=attribute ? node.getAttribute(attribute) : node.nodeValue;
    if (!value) return;
    let entries=originals.get(node);if(!entries){entries=new Map();originals.set(node,entries);}
    const key=attribute||'text';let record=entries.get(key);
    if(!record||value!==record.rendered) record={source:value,rendered:value};
    const rendered=translate(record.source,language);record.rendered=rendered;entries.set(key,record);
    if(value!==rendered){if(attribute)node.setAttribute(attribute,rendered);else node.nodeValue=rendered;}
  }
  function refresh() {
    document.documentElement.lang=language;
    for(const label of document.querySelectorAll(labels)) {
      const walker=document.createTreeWalker(label,NodeFilter.SHOW_TEXT);
      while(walker.nextNode())bind(walker.currentNode);
    }
    for(const node of document.querySelectorAll('[title],[aria-label]')) {
      if(node.hasAttribute('data-language-button'))continue;
      bind(node,'title');bind(node,'aria-label');
    }
    const button=document.querySelector('[data-language-button]');
    if(button){const text=language==='ru'?'RU':'EN';if(button.textContent!==text)button.textContent=text;button.title=language==='ru'?'Язык: русский. Switch to English':'Language: English. Переключить на русский';button.setAttribute('aria-label',button.title);}
  }
  async function setLanguage(value) {
    if(!['ru','en'].includes(value))throw Error('Unknown language');
    if(window.hop.setLanguage)await window.hop.setLanguage(value);
    language=value;refresh();window.dispatchEvent(new CustomEvent('hop-language',{detail:value}));
    return value;
  }
  window.hopI18n={translate:value=>translate(value,language),setLanguage,get language(){return language;}};
  document.addEventListener('DOMContentLoaded',async()=>{
    const button=document.createElement('button');button.type='button';button.dataset.languageButton='';button.setAttribute('role','button');button.style.cssText='font:600 11px system-ui;min-width:30px';
    button.addEventListener('click',()=>setLanguage(language==='ru'?'en':'ru').catch(console.error));
    document.getElementById('themeSwitch').append(button);
    new MutationObserver(refresh).observe(document.body,{childList:true,subtree:true,characterData:true});
    refresh();
    try {const saved=await window.hop.getLanguage();language=saved==='en'?'en':'ru';refresh();window.dispatchEvent(new CustomEvent('hop-language',{detail:language}));}catch(error){console.error(error);}
  });
})();
