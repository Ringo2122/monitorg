# encoding: utf-8
#
# SEO-страницы (21.10.2026, этап 1 — готовые HTML-страницы; правила — SEO/SEO-разверстка-2026.md):
#   /<раздел>/ и /<раздел>/<подраздел>/ (+ /2/, /3/ … по 40 лотов), /<раздел>/<подраздел>/<область или город>/,
#   /transport/<подраздел>/<марка>/, /lot/<название-латиницей>-<номер>/, /ploshchadki/<площадка>/, sitemap.xml.
# Текст и ссылки — в самом HTML: поисковик видит их без скриптов. Каталог с фильтрами, кабинет и калькуляторы пока
# живут в приложении на главной (адреса с #); перевод приложения на эти адреса — этап 3.
# Пороги (п. 4): лоты за 12 месяцев (активные + архив); мало — страницу не делаем или закрываем от поиска (noindex).
# ФИО должников-физлиц — никогда в Title, Description и разметке (на странице лота — как в приложении).
# SEO_LIVE=1 — сайт открыт поисковикам; без него все страницы noindex (как сейчас весь сайт до запуска).
require 'json'
require 'cgi'
require 'fileutils'
require 'digest'
require_relative 'brands'

module Pages
  module_function

  SITE = 'https://monitorg.by'
  PER = 40
  ARCH_DAYS = 548                 # архив открыт поисковикам 18 месяцев — столько он и хранится (решение Артёма 21.10)
  YEAR = 365 * 86_400

  REG = { 'г. Минск' => ['minsk', 'в Минске'], 'Минская область' => ['minskaya-oblast', 'в Минской области'],
          'Брестская область' => ['brestskaya-oblast', 'в Брестской области'],
          'Витебская область' => ['vitebskaya-oblast', 'в Витебской области'],
          'Гомельская область' => ['gomelskaya-oblast', 'в Гомельской области'],
          'Гродненская область' => ['grodnenskaya-oblast', 'в Гродненской области'],
          'Могилевская область' => ['mogilevskaya-oblast', 'в Могилёвской области'] }.freeze
  # город или район (regions.rb PLACES) → «в …»: склонять автоматически нельзя («в Гродно», «в Мозыре»)
  CITY_IN = {
    'Минский район' => 'в Минском районе', 'Борисов и район' => 'в Борисове и районе', 'Солигорск и район' => 'в Солигорске и районе',
    'Молодечно и район' => 'в Молодечно и районе', 'Жодино' => 'в Жодино', 'Смолевичский район' => 'в Смолевичском районе',
    'Слуцк и район' => 'в Слуцке и районе', 'Дзержинск и район' => 'в Дзержинске и районе', 'Вилейка и район' => 'в Вилейке и районе',
    'Брест' => 'в Бресте', 'Брестский район' => 'в Брестском районе', 'Барановичи и район' => 'в Барановичах и районе',
    'Пинск и район' => 'в Пинске и районе', 'Кобрин и район' => 'в Кобрине и районе', 'Берёза и район' => 'в Берёзе и районе',
    'Витебск' => 'в Витебске', 'Витебский район' => 'в Витебском районе', 'Орша и район' => 'в Орше и районе',
    'Новополоцк' => 'в Новополоцке', 'Полоцк и район' => 'в Полоцке и районе', 'Гомель' => 'в Гомеле',
    'Гомельский район' => 'в Гомельском районе', 'Мозырь и район' => 'в Мозыре и районе', 'Жлобин и район' => 'в Жлобине и районе',
    'Речица и район' => 'в Речице и районе', 'Светлогорск и район' => 'в Светлогорске и районе',
    'Калинковичи и район' => 'в Калинковичах и районе', 'Рогачёв и район' => 'в Рогачёве и районе', 'Гродно' => 'в Гродно',
    'Гродненский район' => 'в Гродненском районе', 'Лида и район' => 'в Лиде и районе', 'Слоним и район' => 'в Слониме и районе',
    'Волковыск и район' => 'в Волковыске и районе', 'Сморгонь и район' => 'в Сморгони и районе',
    'Новогрудок и район' => 'в Новогрудке и районе', 'Могилёв' => 'в Могилёве', 'Могилёвский район' => 'в Могилёвском районе',
    'Бобруйск и район' => 'в Бобруйске и районе', 'Осиповичи и район' => 'в Осиповичах и районе', 'Горки и район' => 'в Горках и районе'
  }.freeze
  PLAT_NAME = { 'e-auction.by' => 'БелЮрОбеспечение', 'ipmtorgi.by' => 'ИПМ-Торги', 'beltorgi.by' => 'Белреализация',
                'konfiskat.by' => 'Торговый дом «Восточный»', 'belauction.by' => 'БелАукцион', 'minskestate.by' => 'Минск-Недвижимость',
                'mgcn.by' => 'МГЦН', 'auction24.by' => 'Госторги', 'butb.by' => 'БУТБ', 'lotsale.by' => 'LotSale', 'gostorg.by' => 'GOSTORG',
                'bankrot-torg.by' => 'БелБанкротАукцион', 'specrealization.by' => 'СпецРеализация',
                'torgi.gov.by' => 'Единая система электронных торгов', 'etpvit.by' => 'ETPVIT', 'expert-torgi.by' => 'EXPERT ТОРГИ',
                'realtorgi.by' => 'Реалторги', 'iintorgi.by' => 'ИИН Торги' }.freeze
  BRAND_SUBS = %w[legkovye gruzovye avtobusy].freeze
  # [создаём от, открыт поиску: активных от, или всего от] — п. 4 разверстки
  TH = { reg: [10, 3, 20], city: [30, 3, 40], brand: [20, 2, 30] }.freeze
  RES = { 'sold' => 'Продан', 'single' => 'Продан единственному участнику', 'failed' => 'Торги не состоялись',
          'cancelled' => 'Торги отменены' }.freeze

  TR = { 'а' => 'a', 'б' => 'b', 'в' => 'v', 'г' => 'g', 'д' => 'd', 'е' => 'e', 'ё' => 'e', 'э' => 'e', 'ж' => 'zh', 'з' => 'z',
         'и' => 'i', 'й' => 'j', 'к' => 'k', 'л' => 'l', 'м' => 'm', 'н' => 'n', 'о' => 'o', 'п' => 'p', 'р' => 'r', 'с' => 's',
         'т' => 't', 'у' => 'u', 'ф' => 'f', 'х' => 'h', 'ц' => 'c', 'ч' => 'ch', 'ш' => 'sh', 'щ' => 'shch', 'ъ' => '', 'ь' => '',
         'ы' => 'y', 'ю' => 'yu', 'я' => 'ya', 'і' => 'i', 'ў' => 'u' }.freeze

  def slug(s, max = 60)
    t = s.to_s.downcase.chars.map { |c| TR.fetch(c, c) }.join.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')
    t = t[0, max].sub(/-[^-]*\z/, '') if t.size > max
    t
  end

  def h(s)
    CGI.escapeHTML(s.to_s)
  end

  def nf(n)
    n.to_f.round.to_s.reverse.scan(/\d{1,3}/).join(" ").reverse
  end

  def dt(ts)
    Time.at(ts.to_i).getlocal('+03:00').strftime('%d.%m.%Y')
  end

  def dtm(ts)
    Time.at(ts.to_i).getlocal('+03:00').strftime('%d.%m.%Y %H:%M')
  end

  def iso(ts)
    Time.at(ts.to_i).getlocal('+03:00').strftime('%Y-%m-%d')
  end

  # ── имена ──
  # ФИО физлица (и капслоком, и с инициалами) — никогда в Title, H1, Description и разметке (п. 6)
  FIO = /\b[А-ЯЁ][а-яё]+(?:-[А-ЯЁ][а-яё]+)?\s+(?:[А-ЯЁ][а-яё]+\s+[А-ЯЁ][а-яё]+(?:вич|вна|ична|ич)\b|[А-ЯЁ]\.\s?[А-ЯЁ]\.)|
         \b[А-ЯЁ]{2,}(?:-[А-ЯЁ]{2,})?\s+[А-ЯЁ]{2,}\s+[А-ЯЁ]{2,}(?:ВИЧ|ВНА|ИЧНА|ИЧ)\b/x.freeze
  PLATE = /\b\d{4}\s?[А-ЯA-Z]{2}-?\d\b|\b[А-ЯA-Z]{2}\s?\d{4}-?\d\b|\b[А-ЯA-Z]{2}-?\d\s?\d{4}\b/.freeze

  # Очистка (п. 6): без VIN, номерных знаков, инвентарных и кадастровых номеров, номеров кузова, «(Унитарное предприятие …)»,
  # «Лот №», ФИО, капслока и точки в конце. Номера остаются в тексте страницы — по ним ищут.
  def clean(name)
    t = name.to_s.gsub(/\s+/, ' ')
    t = t.sub(/\AЛот\s*№\s*\d+\.?\s*/i, '')
    t = t.gsub(/\([^()]*(?:предприяти|ОАО|ООО|ЗАО|ОДО|УП\b|гражданин|филиал|учреждени|инв\.|Инвентар)[^()]*\)/i, '')
    t = t.gsub(/\(\s*(?:наименование|назначение)\s*[-–:]\s*([^()]+)\)/i) { " (#{$1.strip})" }
    t = t.gsub(/[,;]?\s*(?:идентиф\S*\s+номер|vin|вин)\s*(?:\(vin\))?\s*[:№#-]?\s*[A-HJ-NPR-Z0-9]{8,17}/i, '')
    t = t.gsub(/[,;]?\s*\(?(?:vin|вин)\)?\s*[:№]?\s*[A-HJ-NPR-Z0-9]{11,17}\b/i, '')
    t = t.gsub(/[,;(]*\s*\b(?=[A-HJ-NPR-Z0-9]*\d)(?=[A-HJ-NPR-Z0-9]*[A-HJ-NPR-Z])[A-HJ-NPR-Z0-9]{17}\b\)?/, '')   # VIN без подписи
    t = t.gsub(/[,;]?\s*(?:рег(?:истрационный)?\.?\s*(?:знак|номер|№)|р\/з|г\.?\s*н\.)\s*[:№]?\s*/i, ' ')
    t = t.gsub(/[,;]?\s*(?:#{PLATE.source})/, '')
    t = t.gsub(/(?:\s+с)?[,;]?\s*(?:инв(?:ентарный)?\.?\s*(?:№|номер)?|№\s*кузова(?:\/рамы)?|кузов(?:,?\s*рама)?\s*(?:\(рама\))?\s*№|кадастровый\s+номер)\s*[:№]?\s*[\w\/.-]+/i, '')
    t = t.gsub(/\s+[А-ЯA-Z]{2}-\d\s+\d{4}\b/, '')   # «СЕ-4 2620» — тракторный номер
    t = t.gsub(FIO, 'физическое лицо')
    t = t.gsub(/\n.*/m, '').gsub(/\s+([,.;:)])/, '\1').gsub(/[,;:\s(]+\z/, '').gsub(/\(\s*\)/, '').gsub(/\s{2,}/, ' ').strip
    t = t.sub(/(?<![\s.][а-яa-z])\.\z/i, '')   # точку в конце убираем, «г.в.» оставляем
    letters = t.scan(/[А-ЯЁA-Zа-яёa-z]/)
    if letters.size > 6 && letters.count { |c| c =~ /[А-ЯЁA-Z]/ } > letters.size * 0.8
      # капслок: русские слова — строчными (кроме первого), латиница и слова с цифрами — как есть (E 220, 2ПТС-4)
      t = t.split(/(\s+)/).map { |w| w =~ /\d/ || w !~ /[А-ЯЁ]/ ? w : w.downcase }.join
      t = t[0].upcase + t[1..-1].to_s
    end
    t.empty? ? 'Лот' : t
  end

  def area_txt(l, txt)
    a = l['area_num'].to_f
    a = txt[/площадь[юи]?\s*[-–:]?\s*(\d[\d\s]*[.,]?\d*)\s*(?:кв\.?\s*м|м2|м²)/i, 1].to_s.delete(' ').tr(',', '.').to_f if a <= 0
    return nil unless a.positive?
    a >= 10_000 && txt =~ /\bга\b/ ? nil : "#{format(a % 1 == 0 ? '%d' : '%.1f', a).tr('.', ',')} м²"
  end

  def settlement(l)
    l['location'].to_s[/(?:\A|[\s,])(?:г\.|город|аг\.|д\.|гп|г\.\s?п\.|п\.)\s*([А-ЯЁ][а-яё]+(?:[- ][А-ЯЁ][а-яё]+)?)/, 1]
  end

  # Короткое имя (п. 6): легковые — «Марка Модель, год»; недвижимость и аренда — «Вид площадь м²»; остальное — начало названия
  def short(l, rows)
    t = clean(l['name'])
    top, sub = l['sub'].to_s.split('/')
    if l['sub'] == 'transport/legkovye' && l['brand'] && l['brand'] != 'Другие'
      # модель — из строки «Модель» карточки, иначе — слова после марки в названии или в «Марка (модель)»
      yr = ((rows.find { |k, _| k.to_s =~ /\AГод/ } || [])[1].to_s[/(19|20)\d\d/] || l['name'].to_s[/\b(19[89]\d|20[0-2]\d)\b/])
      model = (rows.find { |k, _| k.to_s =~ /\AМодель/ } || [])[1].to_s.strip
      if model.empty? || model.size > 30
        re = Brands::LIST[l['brand']]
        src = [(rows.find { |k, _| k.to_s =~ /\AМарка/ } || [])[1].to_s, l['name'].to_s].find { |x| Brands.norm(x) =~ re }
        if src && (m = Brands.norm(src).match(re))
          model = src[m.end(0)..-1].to_s.sub(/\A[\s,-]+/, '')[/\A[^,;(]+/].to_s.split.first(2).join(' ')
          model = '' if model =~ /\A(?:19|20)\d\d\b/
        end
      end
      model = model.sub(/\A#{Regexp.escape(l['brand'])}\s*/i, '').split.map { |w| w =~ /\A[A-ZА-ЯЁ]{3,}\z/ ? w.capitalize : w }.join(' ')
      return [l['brand'].sub(' (ВАЗ)', ''), model].reject(&:empty?).join(' ') + (yr ? ", #{yr}" : '')
    elsif sub == 'doli' && (fr = t[/\A\s*(\d+\s*\/\s*\d+)/, 1])
      # «1/2 доли: жилой дом, Ворняны»
      obj = t[/собственности\s+на\s+([^,;(:]+?)(?=\s+(?:с\s+инв|площадью|общей|расположен|по адресу|в\s+(?:аг|д|г|гп|п)\.)|[,;(:]|\z)/i, 1].to_s.strip
      t = ["#{fr.delete(' ')} доли#{obj.empty? ? '' : " на #{obj}"}", settlement(l)].compact.join(', ')
    elsif %w[nedvizhimost arenda].include?(top)
      txt = "#{l['name']} #{rows.map { |r| r.join(' ') }.join(' ')}"
      kind = t[/\(([^()]{3,40})\)/, 1] if t =~ /\A(?:капитальн|изолированн|незаверш|объект)/i   # «Капитальное строение (коровник)» → коровник
      kind ||= t.sub(/\A(?:(?:продажа|аукцион)\s+(?:на\s+)?)?(?:прав[оа]\s+(?:на\s+)?(?:заключени[ея]\s+)?(?:договора\s+)?)?аренд[аыу]\s+/i, '')[/\A[^,;(]+?(?=\s+(?:площадью|общей|пл\.|расположен|по адресу|в\s+(?:аг|д|г|гп|п)\.|с\s+инв|№)|[,;(]|\z)/i].to_s
      kind = kind.strip.split.first(5).join(' ')
      kind = kind[0].upcase + kind[1..-1].to_s unless kind.empty?
      parts = [kind, area_txt(l, txt)].compact.reject(&:empty?).join(' ')
      parts = "Аренда: #{parts[0].downcase}#{parts[1..-1]}" if top == 'arenda' && !parts.empty?
      st = settlement(l)
      t = [parts, st].compact.reject(&:empty?).join(', ') unless parts.empty?
    end
    t.size > 55 ? t[0, 55].sub(/[\s,;:(-]+[^\s]*\z/, '') : t
  end

  def town(l)
    return 'Минск' if l['region'] == 'г. Минск'
    settlement(l) || l['region'].to_s.sub(' область', ' обл.')
  end

  # Title лота: «{Короткое имя}, {город} — {итог}» не длиннее ~65 знаков: короче — за счёт имени, по границе слова
  def lot_title(sh, tn, tail)
    tn = nil if tn.to_s.empty? || sh.include?(tn.to_s)
    t = "#{sh}#{tn ? ", #{tn}" : ''} — #{tail}"
    return t if t.size <= 75
    t = "#{sh} — #{tail}"
    return t if t.size <= 75
    room = [75 - tail.size - 3, 25].max
    "#{sh[0, room].sub(/\s+\S*\z/, '').sub(/[\s,;:(]+\z/, '')} — #{tail}"
  end

  # номер лота в адресе; у части площадок номер — длинное название (expert-torgi) — тогда приставка и короткий отпечаток
  def idpart(id)
    id.size <= 24 ? slug(id) : "#{id[/\A[a-z0-9]+/]}-#{Digest::MD5.hexdigest(id)[0, 8]}"
  end

  def lot_path(l)
    @lp[l['id']]
  end

  # ── обвязка страницы ──
  def head_tags(title, desc, path, robots, ld)
    <<~HTML
      <!doctype html>
      <html lang="ru"><head><meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="robots" content="#{robots}">
      <title>#{h(title)}</title>
      <meta name="description" content="#{h(desc)}">
      <link rel="canonical" href="#{SITE}#{path}">
      <meta property="og:type" content="website"><meta property="og:site_name" content="МониТорг"><meta property="og:title" content="#{h(title)}"><meta property="og:description" content="#{h(desc)}"><meta property="og:url" content="#{SITE}#{path}">
      <link rel="stylesheet" href="/fonts/fonts.css?v=1"><link rel="stylesheet" href="/assets/site.css?v=#{@ver}">
      <link rel="icon" href="/favicon.ico?v=3" sizes="32x32"><link rel="icon" href="/favicon.svg?v=3" type="image/svg+xml"><link rel="apple-touch-icon" href="/apple-touch-icon.png?v=3">
      #{@theme}
      #{ld.map { |x| %(<script type="application/ld+json">#{JSON.generate(x).gsub('</', '<\/')}</script>) }.join("\n")}
      </head><body>
    HTML
  end

  # шапка — как у сайта (index.html): «Весь каталог», те же пункты меню, поиск, кабинет, «Помощь в аукционе».
  # Пока ведут в приложение на главной (адреса с #); на телефоне меню открывает /assets/page.js
  NAV_LINKS = [['/#/', 'Главная'], ['/#/catalog', 'Все лоты'], ['/#/catalog?st=arch', 'Архив'], ['/#/calc', 'Калькуляторы'],
               ['/#/news', 'Новости'], ['/#/about', 'О платформе']].freeze
  def header
    grid = '<span class="cg"><svg class="g" viewBox="0 0 24 24"><rect x="4" y="4" width="6.5" height="6.5" rx="1.6"/><rect x="13.5" y="4" width="6.5" height="6.5" rx="1.6"/>' \
           '<rect x="4" y="13.5" width="6.5" height="6.5" rx="1.6"/><rect x="13.5" y="13.5" width="6.5" height="6.5" rx="1.6"/></svg></span>'
    nav = %(<li class="cm-li"><a class="cbtn" href="/#/catalog">#{grid}<span>Весь каталог</span></a></li>) +
          NAV_LINKS.map { |u, t| %(<li><a href="#{u}">#{t}</a></li>) }.join
    <<~HTML
      <header class="main"><div class="wrap hrow">
        <a class="logo" href="/"><img class="mark ml" src="/logo-mark.png" alt=""><img class="mark md" src="/logo-mark-dark.png" alt="">
          <span class="lt"><span class="nm">МониТорг</span><span class="sub">Первый агрегатор<br>торгов Беларуси</span></span></a>
        <nav class="hnav" aria-label="Разделы сайта"><ul id="nav">#{nav}</ul></nav>
        <div class="hacts">
          <a class="hs-btn" href="/#/catalog" aria-label="Поиск по лотам" title="Поиск"><svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="6.5"/><path d="M20 20l-4.2-4.2"/></svg></a>
          <a class="hs-btn ubtn" href="/#/me" aria-label="Личный кабинет" title="Личный кабинет"><svg viewBox="0 0 24 24"><circle cx="12" cy="8" r="4"/><path d="M4 21c0-4.4 3.6-8 8-8s8 3.6 8 8"/></svg></a>
          <a class="btn pri" href="/#/help"><span class="h-long">Помощь в аукционе</span><span class="h-short">Помощь</span></a>
          <button class="hs-btn mburg" id="mburg" type="button" aria-label="Меню" aria-expanded="false" aria-controls="mmenu"><svg class="b" viewBox="0 0 24 24"><path d="M4 7h16M4 12h16M4 17h16"/></svg></button>
        </div>
      </div><div class="mmenu" id="mmenu">#{NAV_LINKS.map { |u, t| %(<a href="#{u}">#{t}</a>) }.join}<a class="btn pri" href="/#/help">Помощь в аукционе</a></div>
      </header><div class="hsp" aria-hidden="true"></div>
    HTML
  end

  def footer
    plats = PLAT_NAME.select { |d, _| @plat_n[d].to_i.positive? }.map { |d, n| %(<li><a href="/ploshchadki/#{slug(d.sub(/\.by\z/, ''))}/">#{h(n)}</a></li>) }.join
    <<~HTML
      <footer class="main"><div class="wrap"><div class="fcols">
        <div><h4>МониТорг</h4><p style="margin:0;color:#a1a1aa">Агрегатор торгов по имуществу должников: банкротство, исполнительное производство, конфискат. Все площадки Беларуси в одном каталоге.</p></div>
        <div class="fsrc"><h4>Площадки</h4><ul>#{plats}</ul></div></div>
        <div class="fbot">Данные собираются с открытых площадок автоматически. Перед участием в торгах проверяйте условия на площадке.
          · <a href="/#/privacy">Политика конфиденциальности</a> · <a href="/#/cookies">Политика cookie</a></div>
      </div></footer><script src="/assets/page.js?v=#{@ver}"></script></body></html>
    HTML
  end

  def crumbs(parts)
    li = [['Главная', '/']] + parts
    vis = li.each_with_index.map { |(t, u), i| i == li.size - 1 || u.nil? ? h(t) : %(<a href="#{u}">#{h(t)}</a>) }.join(' → ')
    ld = { '@context' => 'https://schema.org', '@type' => 'BreadcrumbList',
           'itemListElement' => li.each_with_index.map { |(t, u), i| { '@type' => 'ListItem', 'position' => i + 1, 'name' => t }.merge(u ? { 'item' => SITE + u } : {}) } }
    [%(<div class="crumbs">#{vis}</div>), ld]
  end

  def write(path, title, desc, body, ld, index)
    robots = !@live ? 'noindex, nofollow' : index ? 'index, follow' : 'noindex, follow'
    dir = File.join(@out, path)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'index.html'), head_tags(title, desc, path, robots, ld) + header + %(<main id="app">#{body}</main>) + footer)
    @sitemap << [path, @lastmod[path] || @now] if index
    @n += 1
  end

  # ── карточка лота в списке (как lotCard в приложении) ──
  def card(l)
    arch = l['status'] == 'archive'
    img = l['photo'] ? %(<img src="/ph/#{h(l['photo'])}.jpg" loading="lazy" decoding="async" alt="#{h(@short[l['id']])}">) :
            %(<img src="/noph/#{%w[nedvizhimost avto gruz spec oborud arenda].include?(l['section']) ? l['section'] : 'other'}.svg" alt="Нет фото" loading="lazy">)
    r = l['result']
    ft = if arch
           r && r['price'].to_f.positive? ? %(<span class="rs ok">Продан за #{nf(r['price'])} BYN</span>) :
             r && RES[r['st']] ? %(<span class="rs no">#{RES[r['st']]}</span>) : %(<span>Завершён <b>#{dt(l['closed'])}</b></span>)
         else
           %(<span>Заявки до <b>#{dt(l['req_to'])}</b></span>)
         end
    <<~HTML
      <a class="lot#{arch ? ' arch' : ''} p-#{l['platform'].to_s.split('.').first.gsub(/[^a-z0-9]/, '')}" href="#{lot_path(l)}"><div class="ph">#{img}</div>
      <div class="body"><div class="kind">#{h(@subname[l['sub']])}</div><div class="nm">#{h(clean(l['name']))}</div>
      <div class="pr">#{l['price'].to_f.positive? ? "#{nf(l['price'])} <span>BYN</span>" : '<span>Цена не указана</span>'}</div><div class="loc">#{h(l['location'] || '-')}</div>
      <div class="ft">#{ft}<span class="pl"><i class="pdot"></i>#{h(l['platform'])}</span></div></div></a>
    HTML
  end

  # ── живые цифры раздела (п. 7.2) ──
  def facts(act, done)
    s = []
    if act.any?
      mn = act.map { |l| l['price'].to_f }.select(&:positive?).min
      nx = act.map { |l| l['torg'] || l['req_to'] }.compact.select { |t| t > @now }.min
      s << "Сейчас на торгах #{nf(act.size)} #{plural(act.size, 'лот', 'лота', 'лотов')}" + (mn ? ", цены от #{nf(mn)} BYN" : '') + '.'
      s << "Ближайшие торги — #{dt(nx)}." if nx
    else
      s << 'Сейчас активных лотов нет — ниже итоги прошлых торгов.'
    end
    sold = done.select { |l| (r = l['result']) && r['price'].to_f.positive? && l['closed'].to_i > @now - 90 * 86_400 }
    if sold.size >= 3
      prem = sold.map { |l| l['result']['price'].to_f / [l['result']['start'].to_f, l['price'].to_f].max }.select { |x| x > 0 }.sort
      m = prem[prem.size / 2]
      s << "За последние 3 месяца #{plural_n(sold.size, 'продан', 'продано', 'продано')} #{nf(sold.size)} #{plural(sold.size, 'лот', 'лота', 'лотов')}" +
           (m && m >= 1.01 ? ", обычно на #{((m - 1) * 100).round}% дороже начальной цены." : ', обычно по начальной цене.')
    end
    s.join(' ')
  end

  def plural(n, a, b, c)
    n10 = n % 10
    n100 = n % 100
    n10 == 1 && n100 != 11 ? a : (2..4).cover?(n10) && !(12..14).cover?(n100) ? b : c
  end

  def plural_n(n, a, b, c)
    plural(n, a, b, c)
  end

  # «21 лот», «0 лотов» — для описаний
  def lots_n(n)
    "#{nf(n)} #{plural(n, 'лот', 'лота', 'лотов')}"
  end

  # ── страница списка ──
  def list_page(path, title, h1, desc, crumbs_parts, act, done, links, app_link, index)
    cr, ld_b = crumbs(crumbs_parts)
    pages = [(act.size + PER - 1) / PER, 1].max
    results = done.select { |l| l['result'] && l['result']['price'].to_f.positive? }.sort_by { |l| -l['closed'].to_i }.first(8)
    (1..pages).each do |pg|
      chunk = act[(pg - 1) * PER, PER] || []
      p = pg == 1 ? path : "#{path}#{pg}/"
      pager = pages > 1 ? %(<nav class="pager">) + (1..pages).map { |i| i == pg ? "<b>#{i}</b>" : %(<a href="#{i == 1 ? path : "#{path}#{i}/"}">#{i}</a>) }.join(' ') + '</nav>' : ''
      ld_list = { '@context' => 'https://schema.org', '@type' => 'ItemList',
                  'itemListElement' => chunk.each_with_index.map { |l, i| { '@type' => 'ListItem', 'position' => (pg - 1) * PER + i + 1, 'url' => SITE + lot_path(l) } } }
      body = <<~HTML
        <div class="wrap">#{cr}
        <div class="cat-head"><h1>#{h(h1)}#{pg > 1 ? " — страница #{pg}" : ''}</h1><p class="lede">#{h(facts(act, done))}</p></div>
        #{chunk.any? ? %(<div class="grid">#{chunk.map { |l| card(l) }.join}</div>) : '<div class="panel empty">Сейчас активных лотов нет.</div>'}
        #{pager}
        #{pg == 1 && results.any? ? %(<section class="sec"><div class="sec-h"><h2>Итоги последних торгов</h2></div><div class="grid">#{results.map { |l| card(l) }.join}</div></section>) : ''}
        #{pg == 1 ? links.map { |hd, items| items.empty? ? '' : %(<section class="sec seo-links"><h2>#{h(hd)}</h2><ul>#{items.map { |t, u, n| %(<li><a href="#{u}">#{h(t)}</a>#{n ? " <small>#{nf(n)}</small>" : ''}</li>) }.join}</ul></section>) }.join : ''}

        </div>
      HTML
      write(p, pg > 1 ? "#{title} — страница #{pg}" : title, desc, body, [ld_b, ld_list], index)
    end
  end

  def title_fit(t)
    t.size > 60 ? t.sub(' | МониТорг', '') : t
  end

  # ── страница лота ──
  def lot_meta(l)
    arch = l['status'] == 'archive'
    sh = @short[l['id']]
    tn = town(l)
    r = l['result']
    st = r && RES[r['st']] ? r['st'] : nil
    price = l['price'].to_f.positive? ? "#{nf(l['price'])} BYN" : nil
    plat = "на площадке «#{PLAT_NAME[l['platform']] || l['platform']}»"
    reg = l['region'].to_s.empty? ? nil : l['region']
    tail, desc =
      if !arch
        ["торги #{dt(l['torg'] || l['req_to'])}",
         [price ? "Начальная цена #{price}" : 'Цена — в условиях торгов', "заявки до #{dt(l['req_to'])}."].join(', ') +
           " Торги #{plat}.#{reg ? " #{reg}." : ''} Похожие лоты и итоги торгов — на МониТорге."]
      elsif %w[sold single].include?(st) && r['price'].to_f.positive?
        ["продан за #{nf(r['price'])} BYN",
         "Итоги торгов #{dt(r['at'] || l['closed'])}: продан за #{nf(r['price'])} BYN" +
           ((r['start'] || l['price']).to_f.positive? ? " при начальной #{nf(r['start'] || l['price'])} BYN" : '') +
           "#{r['bids'].to_i.positive? ? ", ставок: #{r['bids']}" : ''}. Похожие лоты на торгах сейчас."]
      elsif st == 'failed'
        ["торги #{dt(r['at'] || l['closed'])} не состоялись",
         "Торги #{dt(r['at'] || l['closed'])} не состоялись#{price ? ", начальная цена #{price}" : ''}. Такие лоты часто выставляют снова со скидкой — следите на МониТорге."]
      elsif l['why'] == 'removed'
        ['снят с торгов', 'Лот снят с торгов до аукциона. Похожие объекты на торгах сейчас.']
      else
        ["торги завершены #{dt(l['closed'])}",
         "Приём заявок завершён #{dt(l['closed'])}#{price ? ", начальная цена #{price}" : ''}. Похожие лоты на торгах сейчас."]
      end
    [lot_title(sh, tn, tail), desc[0, 300], tail]
  end

  def lot_page(l)
    rows_secs = @details.call(l['key'])
    arch = l['status'] == 'archive'
    sh = @short[l['id']]
    r = l['result']
    st = r && RES[r['st']] ? r['st'] : nil
    price = l['price'].to_f.positive? ? "#{nf(l['price'])} BYN" : nil
    reg = l['region'].to_s.empty? ? nil : l['region']
    title, desc = @meta[l['id']]
    top_k, sub_k = l['sub'].to_s.split('/')
    top = @tops.find { |t| t[:k] == top_k }
    parts = []
    parts << [top[:n], "/#{top_k}/"] if top
    parts << [@subname[l['sub']], "/#{l['sub']}/"] if sub_k
    rp = @pages_of_scope["#{l['sub']}|#{REG.dig(l['region'], 0)}"]
    parts << [l['region'], rp] if rp
    parts << [sh, nil]
    cr, ld_b = crumbs(parts)
    plat_p = "/ploshchadki/#{slug(l['platform'].to_s.sub(/\.by\z/, ''))}/"
    img = l['photo'] ? %(<img class="big" src="/ph/#{h(l['photo'])}.jpg" alt="#{h(sh)} — фото 1">) : ''
    res = if st
            p = r['price'].to_f.positive? && (r['start'] || l['price']).to_f.positive? ? ((r['price'].to_f / (r['start'] || l['price']).to_f - 1) * 100).round : nil
            %(<div class="panel res"><div class="hd">Итог торгов #{dt(r['at'] || l['closed'])}</div><div class="bigprice" style="font-size:24px">#{RES[st]}#{r['price'].to_f.positive? ? " за #{nf(r['price'])} BYN" : ''}</div>) +
              (p ? %(<div class="sub">#{p >= 0 ? '+' : '−'}#{p.abs}% к начальной цене #{nf(r['start'] || l['price'])} BYN</div>) : '') +
              ([r['bids'].to_i.positive? ? "Ставок: #{r['bids']}" : nil, r['users'].to_i.positive? ? "участников: #{r['users']}" : nil].compact.join(' · ').then { |x| x.empty? ? '' : %(<div class="sub">#{x}</div>) }) + '</div>'
          else
            ''
          end
    similar = (@act_by_sub[l['sub']] || []).reject { |x| x['id'] == l['id'] }
    similar = (similar.select { |x| x['region'] == l['region'] } + similar).uniq.first(6)
    links = l['sub'] ? [[@subname[l['sub']], "/#{l['sub']}/"]] : []
    links << ["#{@subname[l['sub']]} #{REG.dig(l['region'], 1)}", rp] if rp
    bp = l['brand'] && @pages_of_scope["#{l['sub']}|#{slug(l['brand'])}"]
    links << ["#{l['brand']} с торгов", bp] if bp
    links << ["Все лоты #{PLAT_NAME[l['platform']] || l['platform']}", plat_p]
    sec_html = rows_secs.map do |s|
      rws = (s['rows'] || []).map { |k, v| v.to_s.size > 180 || k.to_s.empty? ? %(<div class="wide">#{k.to_s.empty? ? '' : %(<div class="k2">#{h(k)}</div>)}#{h(v)}</div>) : %(<div class="k">#{h(k)}</div><div>#{h(v)}</div>) }.join
      %(<details class="acc" open><summary>#{h(s['h'])}</summary><div class="acc-b"><div class="rows">#{rws}</div></div></details>)
    end.join
    body = <<~HTML
      <div class="wrap">#{cr}
      <div class="lothead"><div class="tags"><span class="tag">#{h(@subname[l['sub']])}</span><span class="tag g">#{h(l['platform'])}</span><span class="tag g mono">№ #{h(l['art'])}</span>#{arch ? '<span class="tag a">Архив</span>' : ''}</div>
        <h1>#{h(clean(l['name']).then { |x| x.size > 200 ? x[0, 200].sub(/\s+\S*\z/, '') + '…' : x })}</h1><div class="addr">#{h(l['location'])}</div></div>
      <div class="lotpage"><div class="gal">#{img}</div><div class="rcol">
        <aside class="panel buy"><div class="lbl">Стартовая цена</div><div class="bigprice">#{price || 'Не указана'}</div>
          <dl class="facts"><dt>Приём заявок</dt><dd>#{arch ? "завершён #{dt(l['closed'])}" : "до <b>#{dtm(l['req_to'])}</b>"}</dd>
            #{l['torg'] ? "<dt>Торги</dt><dd>#{dtm(l['torg'])}</dd>" : ''}<dt>Регион</dt><dd>#{h(reg || '-')}</dd>
            <dt>Площадка</dt><dd><a href="#{plat_p}">#{h(PLAT_NAME[l['platform']] || l['platform'])}</a></dd></dl>
          <div class="cta"><a class="btn" href="#{h(l['url'])}" target="_blank" rel="noopener nofollow">На площадке ↗</a>
            <a class="btn pri" href="/#/help?lot=#{CGI.escape(l['art'].to_s)}&amp;id=#{CGI.escape(l['id'])}">Помощь с этим лотом</a></div></aside>
        #{res}</div></div>
      #{sec_html.empty? ? '' : %(<h2 class="accs-h">Сведения о лоте</h2><div class="accs">#{sec_html}</div>)}
      #{similar.any? ? %(<section class="sec"><div class="sec-h"><h2>#{arch ? 'Похожие лоты на торгах сейчас' : 'Похожие лоты'}</h2></div><div class="grid">#{similar.map { |x| card(x) }.join}</div></section>) : ''}
      <section class="sec seo-links"><h2>Смотрите также</h2><ul>#{links.map { |t, u| %(<li><a href="#{u}">#{h(t)}</a></li>) }.join}</ul></section>
      </div>
    HTML
    offer = { '@type' => 'Offer', 'priceCurrency' => 'BYN', 'url' => SITE + lot_path(l),
              'availability' => arch ? (%w[sold single].include?(st) ? 'https://schema.org/SoldOut' : 'https://schema.org/Discontinued') : 'https://schema.org/InStock' }
    offer['priceValidUntil'] = iso(l['req_to']) unless arch
    offer['price'] = l['price'].to_f.round(2) if l['price'].to_f.positive?
    prod = { '@context' => 'https://schema.org', '@type' => 'Product', 'name' => clean(l['name'])[0, 150], 'sku' => l['id'] }
    prod['offers'] = offer if offer['price']   # цены нет — без предложения: пустая цена — ошибка разметки
    prod['image'] = "#{SITE}/ph/#{l['photo']}.jpg" if l['photo']
    prod['brand'] = { '@type' => 'Brand', 'name' => l['brand'] } if l['brand'] && l['brand'] != 'Другие'
    open = !arch || l['closed'].to_i > @now - ARCH_DAYS * 86_400
    write(lot_path(l), title, desc, body, [ld_b, prod], open)
  end

  # ── всё вместе ──
  # out — папка сайта; active, arch — показанные лоты; details — ->(key) { [{h, rows}] }; tree — Cats.tree
  def run(out:, active:, arch:, details:, tree:, now:, template:, theme:, ver:, live: false)
    @out = out
    @now = now
    @live = live
    @ver = ver
    @details = details
    @n = 0
    @sitemap = []
    @lastmod = {}
    @tops = tree.map { |t| { k: t['k'], n: t['n'], subs: t['subs'] } }
    @subname = {}
    @tops.each { |t| t[:subs].each { |s| @subname["#{t[:k]}/#{s['k']}"] = s['n'] } }
    all = active + arch.select { |l| l['closed'].to_i > now - ARCH_DAYS * 86_400 }
    @plat_n = Hash.new(0)
    active.each { |l| @plat_n[l['platform']] += 1 }
    arch.each { |l| @plat_n[l['platform']] += 1 }

    # стили и тема — из шаблона приложения: страницы выглядят так же
    FileUtils.mkdir_p(File.join(out, 'assets'))
    File.write(File.join(out, 'assets', 'site.css'), template[%r{<style>(.*?)</style>}m, 1].to_s +
      "\n.pager{display:flex;flex-wrap:wrap;gap:8px;margin:18px 0}.pager a,.pager b{padding:6px 12px;border:1px solid var(--hair);border-radius:8px}" \
      ".pager b{background:var(--brand);color:#fff;border-color:var(--brand)}.seo-links ul{display:flex;flex-wrap:wrap;gap:8px 18px;padding:0;list-style:none}" \
      ".seo-links small{color:var(--ink-3)}" \
      ".hnav a.cbtn{display:flex;padding:0 15px 0 6px;color:#fff;font-size:14px}.hnav a.cbtn:hover{background:var(--accent-h);color:#fff}" \
      ".panel.res{padding:14px 16px;margin-top:15px}.panel.res .sub{color:var(--ink-2);font-size:13px;margin-top:4px}\n")
    File.write(File.join(out, 'assets', 'theme.js'), template[%r{<script>\s*(/\* Общий стиль.*?)</script>}m, 1].to_s.sub('__THEME__') { theme })
    @theme = %(<script src="/assets/theme.js?v=#{ver}"></script>)
    # меню на телефоне и прилипающая шапка — минимум из приложения
    File.write(File.join(out, 'assets', 'page.js'), <<~JS)
      (function(){var b=document.getElementById('mburg'),r=document.documentElement;
      if(b)b.onclick=function(e){e.stopPropagation();var on=!r.classList.contains('mm-open');r.classList.toggle('mm-open',on);b.setAttribute('aria-expanded',on);};
      document.addEventListener('click',function(e){if(r.classList.contains('mm-open')&&!e.target.closest('#mmenu,#mburg'))r.classList.remove('mm-open');});
      var h=document.querySelector('header.main');if(h)r.style.setProperty('--hh',h.offsetHeight+'px');
      var cb=document.querySelector('.hnav .cbtn'),row=document.querySelector('header.main .hrow'),lg=document.querySelector('header.main .logo'),ac=document.querySelector('header.main .hacts');
      function fit(){if(!cb||!row)return;cb.classList.remove('ico');var pr=parseFloat(getComputedStyle(row).paddingRight)||0;
        if(ac.getBoundingClientRect().right>row.getBoundingClientRect().right-pr+1||lg.scrollWidth>lg.clientWidth+1)cb.classList.add('ico');}
      fit();addEventListener('resize',fit);if(document.fonts)document.fonts.ready.then(fit);})();
    JS

    # имена и адреса лотов
    @short = {}
    @lp = {}
    all.each do |l|
      rows = details.call(l['key']).flat_map { |s| s['rows'] || [] }
      # марка у архивных — тоже (в сборке она пока только у активных): короткое имя и страницы марок
      l['brand'] ||= Brands.of(l, rows) if BRAND_SUBS.include?(l['sub'].to_s.split('/')[1]) && l['sub'].to_s.start_with?('transport/')
      sh = short(l, rows)
      @short[l['id']] = sh
      @lp[l['id']] = "/lot/#{[slug(sh, 50), idpart(l['id'])].reject(&:empty?).join('-')}/"
    end

    recent = ->(l) { l['status'] == 'active' || l['closed'].to_i > now - YEAR }
    @act_by_sub = active.group_by { |l| l['sub'] }
    @pages_of_scope = {}

    # срезы подраздела: области, города, марки — сначала решаем, какие страницы будут (нужны для ссылок)
    plans = []
    @tops.each do |t|
      t[:subs].each do |s|
        sp = "#{t[:k]}/#{s['k']}"
        lots = all.select { |l| l['sub'] == sp }
        REG.each do |reg, (rs, rin)|
          ls = lots.select { |l| l['region'] == reg }
          yr = ls.count(&recent)
          next if yr < TH[:reg][0]
          act = ls.count { |l| l['status'] == 'active' }
          plans << [:reg, sp, reg, rs, rin, ls, act >= TH[:reg][1] || yr >= TH[:reg][2]]
          @pages_of_scope["#{sp}|#{rs}"] = "/#{sp}/#{rs}/"
        end
        CITY_IN.each do |city, cin|
          ls = lots.select { |l| l['city'] == city }
          yr = ls.count(&recent)
          next if yr < TH[:city][0]
          cs = slug(city.sub(' и район', ''))
          act = ls.count { |l| l['status'] == 'active' }
          plans << [:city, sp, city, cs, cin, ls, act >= TH[:city][1] || yr >= TH[:city][2]]
          @pages_of_scope["#{sp}|#{cs}"] = "/#{sp}/#{cs}/"
        end
        next unless t[:k] == 'transport' && BRAND_SUBS.include?(s['k'])
        lots.group_by { |l| l['brand'] }.each do |b, ls|
          next if b.nil? || b == 'Другие'
          yr = ls.count(&recent)
          next if yr < TH[:brand][0]
          bs = slug(b)
          act = ls.count { |l| l['status'] == 'active' }
          plans << [:brand, sp, b, bs, nil, ls, act >= TH[:brand][1] || yr >= TH[:brand][2]]
          @pages_of_scope["#{sp}|#{bs}"] = "/#{sp}/#{bs}/"
        end
      end
    end
    dup = @pages_of_scope.values.group_by(&:itself).select { |_, v| v.size > 1 }.keys
    warn "SEO: совпали адреса страниц: #{dup.join(', ')}" if dup.any?

    split = ->(ls) { [ls.select { |l| l['status'] == 'active' }.sort_by { |l| l['req_to'].to_i }, ls.reject { |l| l['status'] == 'active' }] }

    # разделы и подразделы
    @tops.each do |t|
      tl = all.select { |l| l['sub'].to_s.start_with?("#{t[:k]}/") }
      act, done = split.(tl)
      subs = t[:subs].map { |s| [s['n'], "/#{t[:k]}/#{s['k']}/", act.count { |l| l['sub'] == "#{t[:k]}/#{s['k']}" }] }
      big = subs.sort_by { |x| -x[2] }.first(3).map { |x| x[0].downcase }.join(', ')
      mn = act.map { |l| l['price'].to_f }.select(&:positive?).min
      list_page("/#{t[:k]}/", title_fit("#{t[:n]} с торгов в Беларуси | МониТорг"), "#{t[:n]} с торгов",
                "#{act.any? ? "#{lots_n(act.size)} на торгах: #{big}.#{mn ? " Цены от #{nf(mn)} BYN." : ''}" : 'Сейчас активных лотов нет.'} Итоги прошлых торгов, все площадки Беларуси.",
                [[t[:n], nil]], act, done, [['Подразделы', subs]], "/#/c/#{t[:k]}", true)
      t[:subs].each do |s|
        sp = "#{t[:k]}/#{s['k']}"
        sl = tl.select { |l| l['sub'] == sp }
        a2, d2 = split.(sl)
        mn = a2.map { |l| l['price'].to_f }.select(&:positive?).min
        regs = plans.select { |x| x[0] == :reg && x[1] == sp }.map { |x| [x[2], "/#{sp}/#{x[3]}/", x[5].count { |l| l['status'] == 'active' }] }
        cits = plans.select { |x| x[0] == :city && x[1] == sp }.map { |x| [x[2], "/#{sp}/#{x[3]}/", x[5].count { |l| l['status'] == 'active' }] }
        brs = plans.select { |x| x[0] == :brand && x[1] == sp }.map { |x| [x[2], "/#{sp}/#{x[3]}/", x[5].count { |l| l['status'] == 'active' }] }
        nb = t[:subs].reject { |x| x['k'] == s['k'] }.map { |x| [x['n'], "/#{t[:k]}/#{x['k']}/", nil] }
        sn = t[:k] == 'arenda' ? "Право аренды: #{s['n'].downcase}" : s['n']
        list_page("/#{sp}/", title_fit("#{sn} — торги в Беларуси | МониТорг"), t[:k] == 'arenda' ? sn : "#{s['n']} с торгов",
                  "#{a2.any? ? "#{lots_n(a2.size)} на торгах сейчас#{mn ? ", цены от #{nf(mn)} BYN" : ''}." : 'Сейчас активных лотов нет.'} Конфискат, банкротство, исполнительное производство. Итоги прошлых торгов.",
                  [[t[:n], "/#{t[:k]}/"], [s['n'], nil]], a2, d2,
                  [['По регионам', regs], ['По городам и районам', cits], ['Марки', brs.sort_by { |x| -x[2] }], ['Соседние разделы', nb]], "/#/c/#{sp}", true)
      end
    end

    # срезы
    plans.each do |kind, sp, name, sl, inn, ls, index|
      t = @tops.find { |x| sp.start_with?("#{x[:k]}/") }
      sn = sp.start_with?('arenda/') ? "Право аренды: #{@subname[sp].downcase}" : @subname[sp]
      act, done = split.(ls)
      mn = act.map { |l| l['price'].to_f }.select(&:positive?).min
      nx = act.map { |l| l['torg'] || l['req_to'] }.compact.select { |x| x > now }.min
      path = "/#{sp}/#{sl}/"
      sibs = plans.select { |x| x[0] == kind && x[1] == sp && x[3] != sl }.map { |x| [x[2], "/#{sp}/#{x[3]}/", x[5].count { |l| l['status'] == 'active' }] }
      if kind == :brand
        list_page(path, title_fit("#{sn} #{name} с торгов в Беларуси | МониТорг"), "#{sn} #{name} с торгов",
                  "#{name}: #{act.any? ? "#{lots_n(act.size)} на торгах#{mn ? ", цены от #{nf(mn)} BYN" : ''}" : 'сейчас активных лотов нет'}. За сколько уходили #{name} на прошлых торгах — итоги и цены.",
                  [[t[:n], "/#{t[:k]}/"], [sn, "/#{sp}/"], [name, nil]], act, done, [['Другие марки', sibs.sort_by { |x| -x[2] }]], "/#/c/#{sp}?brand=#{CGI.escape(name)}", index)
      else
        list_page(path, title_fit("#{sn}#{sp.start_with?('arenda/') ? ' —' : ' с'} торгов #{inn} | МониТорг"), "#{sn}#{sp.start_with?('arenda/') ? ' —' : ' с'} торгов #{inn}",
                  "#{act.any? ? "#{lots_n(act.size)} #{inn}#{mn ? ", цены от #{nf(mn)} BYN" : ''}." : "Сейчас активных лотов #{inn} нет."}#{nx ? " Ближайшие торги #{dt(nx)}." : ''} Итоги прошлых аукционов #{inn}.",
                  [[t[:n], "/#{t[:k]}/"], [sn, "/#{sp}/"], [name, nil]], act, done,
                  [[kind == :reg ? 'Другие регионы' : 'Другие города и районы', sibs]],
                  "/#/c/#{sp}?region=#{CGI.escape(kind == :reg ? name : (ls.first || {})['region'].to_s)}#{kind == :city ? "&city=#{CGI.escape(name)}" : ''}", index)
      end
    end

    # площадки
    all.group_by { |l| l['platform'] }.each do |pl, ls|
      act, done = split.(ls)
      secs = act.group_by { |l| l['sub'].to_s.split('/').first }.map { |k, v| [(@tops.find { |t| t[:k] == k } || {})[:n], v.size] }.select(&:first)
      nm = PLAT_NAME[pl] || pl
      list_page("/ploshchadki/#{slug(pl.sub(/\.by\z/, ''))}/", title_fit("#{nm} (#{pl}) — все лоты на торгах | МониТорг"), "Лоты площадки «#{nm}»",
                "#{lots_n(act.size)} на площадке «#{nm}»: #{secs.map { |n, c| "#{n.downcase} — #{c}" }.join(', ')}. Итоги торгов и удобный поиск — на МониТорге.",
                [['Площадки', nil], [nm, nil]], act, done, [], "/#/catalog?plat=#{CGI.escape(pl)}", true)
    end

    # лоты: одинаковый заголовок у разных лотов (одинаковые гаражи, машины одной модели) — дописываем номер лота
    @meta = all.to_h { |l| [l['id'], lot_meta(l)] }
    art = all.to_h { |l| [l['id'], l['art']] }
    dup = @meta.values.group_by(&:first).select { |_, v| v.size > 1 }.keys.to_h { |t| [t, true] }
    @meta.each { |id, m| m[0] = m[0].sub(" — #{m[2]}", ", лот № #{art[id]} — #{m[2]}") if dup[m[0]] }
    # у части площадок № лота общий для всего аукциона (БУТБ) — тогда наш номер
    dup = @meta.values.group_by(&:first).select { |_, v| v.size > 1 }.keys.to_h { |t| [t, true] }
    @meta.each { |id, m| m[0] = m[0].sub(/, лот № [^—]+ — /, ", #{id} — ") if dup[m[0]] }
    all.each { |l| lot_page(l) }

    # карта сайта: разделы и срезы отдельно, лоты — частями до 50 000
    lots_sm, other = @sitemap.partition { |p, _| p.start_with?('/lot/') }
    files = { 'sitemap-pages.xml' => other }
    lots_sm.each_slice(45_000).with_index { |sl, i| files["sitemap-lots-#{i + 1}.xml"] = sl }
    files.each do |f, list|
      File.write(File.join(out, f), %(<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n) +
        list.map { |p, t| "<url><loc>#{SITE}#{p}</loc><lastmod>#{iso(t)}</lastmod></url>" }.join("\n") + "\n</urlset>\n")
    end
    File.write(File.join(out, 'sitemap.xml'), %(<?xml version="1.0" encoding="UTF-8"?>\n<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n) +
      files.keys.map { |f| "<sitemap><loc>#{SITE}/#{f}</loc><lastmod>#{iso(now)}</lastmod></sitemap>" }.join("\n") + "\n</sitemapindex>\n")
    # адреса лотов для перехода со старых ссылок (#/lot/<id>) — приложение на главной отправит на новую страницу
    File.write(File.join(out, 'assets', 'lot-urls.json'), JSON.generate(@lp))
    { pages: @n, indexed: @sitemap.size, lots: all.size, slices: plans.size }
  end
end
