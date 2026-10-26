// Shronshiki: отправка писем об упоминаниях из вашей Gmail.
// Google Apps Script (script.google.com) → вставить этот код → Развернуть →
// Новое развёртывание → Веб-приложение (выполнять от моего имени, доступ: все).
// SECRET — значение NOTIFY_SECRET из SQL-миграции mentions.
const SECRET = 'ВСТАВЬТЕ_NOTIFY_SECRET';

function doPost(e) {
  const data = JSON.parse(e.postData.contents);
  if (data.secret !== SECRET) {
    return ContentService.createTextOutput('forbidden');
  }
  MailApp.sendEmail({
    to: data.to,
    subject: data.subject,
    body: data.text,
    name: 'Shronshiki',
  });
  return ContentService.createTextOutput('ok');
}
