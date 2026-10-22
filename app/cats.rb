# encoding: utf-8
module Cats
  TREE = [
    ['transport', 'Транспорт и техника', 'avto', [
      ['legkovye', 'Легковые автомобили'], ['gruzovye', 'Грузовые автомобили'], ['pricepy', 'Прицепы и полуприцепы'],
      ['avtobusy', 'Автобусы и микроавтобусы'], ['spectehnika', 'Спецтехника'], ['selhoztehnika', 'Сельхозтехника'],
      ['prochij', 'Прочий транспорт']]],
    ['nedvizhimost', 'Недвижимость', 'nedvizhimost', [
      ['kvartiry', 'Квартиры и комнаты'], ['doma', 'Жилые дома и дачи'], ['zemlya', 'Земельные участки'],
      ['kommercheskaya', 'Коммерческая недвижимость'], ['sklady', 'Склады и производства'], ['garazhi', 'Гаражи и машиноместа'],
      ['selhoz', 'Сельхозобъекты'], ['doli', 'Доли в имуществе'], ['kompleksy', 'Имущественные комплексы'], ['prochie', 'Прочие объекты']]],
    ['oborudovanie', 'Оборудование и имущество', 'oborud', [
      ['promyshlennoe', 'Промышленное оборудование'], ['stanki', 'Станки и металлообработка'],
      ['torgovoe', 'Торговое и офисное оборудование'], ['prochee', 'Прочее оборудование']]],
    ['arenda', 'Право аренды', 'arenda', [
      ['pomeshcheniya', 'Помещения'], ['zemlya', 'Земельные участки'], ['ploshchadki', 'Открытые площадки'], ['drugoe', 'Другое']]]
  ].freeze

  def self.tree
    TREE.map { |k, n, ic, subs| { 'k' => k, 'n' => n, 'ic' => ic, 'subs' => subs.map { |sk, sn| { 'k' => sk, 'n' => sn } } } }
  end

  def self.valid?(s) TREE.any? { |k, _, _, subs| subs.any? { |sk, _| s == "#{k}/#{sk}" } } end

  L = '(?<![а-яё])'
  def self.rx(s) Regexp.new(s.gsub('\\b<', L), Regexp::IGNORECASE) end

  LAT = 'AaBCcEeHKkMOoPpTXxy'
  CYR = 'АаВСсЕеНКкМОоРрТХху'
  def self.norm(s) s.to_s.gsub(/(?<=[а-яёА-ЯЁ])[#{LAT}]+|[#{LAT}]+(?=[а-яёА-ЯЁ])/) { |w| w.tr(LAT, CYR) } end

  AGRI = rx('трактор|мтз|беларус|комбайн|мотоблок|мини-?трактор|сеялк|сажалк|копалк|картофел|свеклоуб|льноуб|теребилк|плуг|косилк|' \
            'пресс-?подбор|культиватор|опрыскив|жатк|разбрасыв|кормо|борон|дискатор|claas|john.?deere|new.?holland|кзс-?\d|кск-?\d')
  MOTO = rx('мотоцикл|мопед|скутер|квадроцикл|снегоход|мото\b')
  BOAT = rx('\b<лодк|катер|яхт|судно|теплоход')
  TRAILER = rx('полуприцеп|\b<прицеп(?!н)|п/прицеп')
  SPEC = rx('погрузчик|экскаватор|кран|бульдозер|грейдер|каток|манипулятор|автовышк|мусоровоз|ассениз|эвакуатор|форвардер|харвестер')
  TRUCK_BODY = rx('самосвал|тягач|седельн|цистерн|бортов|фургон|рефрижер|изотерм')
  VANS = /crafter|sprinter|transit|ducato|boxer|jumper|\bmaster\b|movano|\bdaily\b|газел|gazel|соболь|\blt ?(28|35|46)\b|vario/i
  BUS_MODEL = /(?:маз|maz)[\s-]*(?:1\d\d|2[0-5]\d)\d{0,3}\b|\bнеман\b|\bпаз\b|\bлиаз\b|ikarus|икарус/i
  VAN_PAS = /пассажир|микроавтобус|автобус|\d+\s*(пасс|посадочн|мест)|classi[ck]bus|kombi|tourneo|combi/i
  VAN_CAR = /грузов|фургон|бортов|рефриж|изотерм|цельнометалл|kasten|самосвал|эвакуат|шасси/i

  NED = [
    ['kvartiry', 'Квартиры и комнаты', '\b<квартир[аы ]|\b<комнат'],
    ['doma', 'Дома', 'жил(ой|ого|ые) дом|коттедж|\b<дач[аи]|садов(ый|ого) дом'],
    ['zemlya', 'Земельные участки', '\A\s*земельн'],
    ['garazhi', 'Гаражи|Машиноместа', 'гараж|машино-?мест|стоянк'],
    ['selhoz', nil, 'коровник|ферм[аы]|телятник|свинарник|зернохран|зерносклад|сенаж|силос|птичник|конюш|кормоцех|зерносуш|мтф|молочно-?товар|овощехран'],
    ['sklady', 'Склады и производства', 'склад|цех|производств|мастерск|котельн|ангар|депо|мельниц|пилорам|лесопил|прачечн|насосн|трансформатор'],
    ['kommercheskaya', 'Коммерческая недвижимость', 'магазин|офис|кафе|торгов|административ|контор|гостиниц|столов|бан[яи]|аптек|ресторан|бар\b|' \
                                                 'павильон|киоск|помещени|здание|капитальн|строени'],
    ['doli', 'Доля в имуществе', '\A\s*\d+\s*/\s*\d+|\A\s*дол[яи]'],
    ['kompleksy', 'Комплекс имущества', 'комплекс']
  ].map { |k, sr, w| [k, sr && Regexp.new("\\A(#{sr})\\z"), rx(w)] }.freeze

  OBOR = [
    ['stanki', 'станок|станк|токарн|фрезер|сверлил|шлифов|гильотин|ножниц|листогиб|сварочн|гибочн|долбёжн|долбежн|расточн|молот|вальц'],
    ['promyshlennoe', 'лини[яи]|установк|компрессор|кот[её]л|генератор|электростанц|трансформатор|насос|дробилк|мельниц|сушил|бетоносмес|' \
                      'деревообр|пилорам|пресс|автомат|агрегат|оборудование для производства|печь|ёмкост|емкост|резервуар|бункер|танк|сборник|' \
                      'цистерн|транспорт[её]р|конвейер|элеватор|машина|аппарат|сепаратор|фильтр|теплообмен|колонн|царг|форм[аы] для|реактор|' \
                      'мешалк|дозатор|экструдер'],
    ['torgovoe', 'холодильн|морозильн|витрин|прилав|кассов|стеллаж|плит[аы]|пароконвект|посудомо|кофемаш|торгов|ларь|шкаф холод|' \
                 'мебел|стол|стул|диван|кресл|компьютер|ноутбук|монитор|принтер|телевизор|телефон|кондиционер|оргтехн|системный блок|сервер|шкаф']
  ].map { |k, w| [k, rx(w)] }.freeze

  AREN = [['pomeshcheniya', rx('помещени|здани|строени|офис|магазин|кафе|киоск|павильон')], ['zemlya', rx('земельн|участ')],
          ['ploshchadki', rx('площадк|территори|стоянк')]].freeze

  def self.card_text(l, details)
    details.call(l['key']).flat_map { |s| s['rows'] || [] }.map { |r| r.last.to_s }.join(' ')
  end

  def self.van(nm, txt, sec)
    t = "#{nm} #{txt}"
    pas = t =~ VAN_PAS
    car = t =~ VAN_CAR
    return 'avtobusy' if pas && !car
    return 'gruzovye' if car
    sec == 'gruz' ? 'gruzovye' : 'avtobusy'
  end

  def self.of(l, details)
    nm = norm(l['name'])
    case l['section']
    when 'avto'
      return 'transport/prochij' if nm =~ rx('\A\s*(мотоцикл|мопед|скутер|квадроцикл)')
      return 'transport/selhoztehnika' if nm =~ rx('\A\s*трактор')
      return 'transport/pricepy' if nm =~ rx('\A\s*(полу)?прицеп|krone|fisso|grew|opalenica|schmitz|k[oö]gel|wielton|\A\s*99\d{4}\b') ||
                                    card_text(l, details) =~ rx('прицепы\s+полуприцепы')
      return 'transport/avtobusy' if nm =~ BUS_MODEL
      return 'transport/' + van(nm, card_text(l, details), 'avto') if nm =~ VANS
      'transport/legkovye'
    when 'gruz', 'spec'
      return 'transport/prochij' if nm =~ MOTO || nm =~ BOAT
      txt = card_text(l, details)
      return 'transport/' + van(nm, txt, l['section']) if nm =~ VANS && l['section'] == 'gruz'
      return 'transport/selhoztehnika' if nm =~ AGRI
      return 'transport/pricepy' if nm =~ TRAILER && nm !~ rx('тягач')
      return 'transport/avtobusy' if nm =~ rx('автобус') || nm =~ BUS_MODEL
      return 'transport/legkovye' if nm =~ rx('легков') && nm !~ rx('грузов')
      rows = details.call(l['key']).flat_map { |s| s['rows'] || [] }
      body = (rows.find { |r| r.first.to_s =~ /тип кузова|тип (?:тс|транспортного средства)|вид транспорт/i } || [])[1].to_s
      body = txt[/тип кузова[:\s]*([а-яёa-z\- ]{3,30})/i, 1].to_s if body.empty?
      return 'transport/avtobusy' if body =~ rx('автобус')
      return 'transport/spectehnika' if nm =~ SPEC
      return 'transport/spectehnika' if l['section'] == 'spec' && "#{nm} #{body}" !~ TRUCK_BODY
      'transport/gruzovye'
    when 'nedvizhimost'
      sub = l['sub_ru'].to_s
      k = NED.find { |_, sr, _| sr && sub =~ sr }
      nm2 = nm =~ /незаверш/i ? nm.gsub(/капитальн\S*|строени\S*|здани\S*|объект\S*|строительств\S*/i, ' ') : nm
      k ||= NED.find { |_, _, w| nm2 =~ w }
      'nedvizhimost/' + (k ? k[0] : 'prochie')
    when 'arenda'
      k = AREN.find { |_, w| nm =~ w }
      'arenda/' + (k ? k[0] : 'drugoe')
    when 'oborud'
      k = OBOR.find { |_, w| nm =~ w }
      'oborudovanie/' + (k ? k[0] : 'prochee')
    end
  end
end
