# encoding: utf-8
YEAR_ARCH = !ENV['YEAR_ARCH'].to_s.empty?
YEAR_DONE = File.join(Store::DATA, 'backfill_year.json')
YEAR_PLATS = %w[e-auction.by ipmtorgi.by beltorgi.by konfiskat.by minskestate.by auction24.by lotsale.by butb.by
                bankrot-torg.by specrealization.by torgi.gov.by etpvit.by expert-torgi.by realtorgi.by iintorgi.by].freeze
ARCH_DAYS = { 'bankrot-torg.by' => 274, 'specrealization.by' => 274, 'etpvit.by' => 274, 'expert-torgi.by' => 274,
              'realtorgi.by' => 274, 'iintorgi.by' => 274, 'torgi.gov.by' => 61 }.freeze
YEAR_PH = [320, 40].freeze
YEAR_PICS = 5
YEAR_KF_DAYS = 90
YEAR_UNTIL = if YEAR_ARCH && ENV['GITHUB_EVENT_NAME'] == 'schedule'
               t = Time.now
               if t.hour >= 22 then Time.local(t.year, t.month, t.day, 6, 30) + 86_400
               elsif t.hour < 7 then Time.local(t.year, t.month, t.day, 6, 30)
               else t
               end
             end

BACK_DAYS = (ENV['BACK_DAYS'] || (YEAR_ARCH ? 365 : 30)).to_i
BACK_CAP = (ENV['BACK_CAP'] || (YEAR_ARCH ? 1_000_000 : 350)).to_i
BACK_MIN = (ENV['BACK_MIN'] || (YEAR_ARCH ? 270 : 25)).to_f
BACK_SKIP = File.join(Store::DATA, 'backfill_skip.json')

def year_done
  File.exist?(YEAR_DONE) ? (JSON.parse(File.read(YEAR_DONE, encoding: 'UTF-8')) rescue {}) : {}
end

def year_left
  YEAR_PLATS - year_done.keys - PLAT_OFF
end

def back_min_ok?(sec, price)
  min = MINP[sec].to_f
  !(min.positive? && price.to_f.positive? && price < min)
end

def back_rec(c, sec, d, r, src, now)
  rec = new_lot(c, sec, d, src, now)
  rec['price'] = r['start'] if r['start'].to_f.positive?
  rec.delete('first_seen')
  rec.merge!('status' => 'archive', 'closed' => rec['req_to'], 'why' => 'deadline', 'bf' => now,
             'prices' => [[rec['req_to'], rec['price']]], 'result' => r.merge('checked' => now, 'tries' => 1))
end

def backfill(db, stat, pstat, now)
  since = now - BACK_DAYS * 86_400
  stop = [Time.now + BACK_MIN * 60, YEAR_UNTIL].compact.min
  mx = Mutex.new
  known = ->(k) { mx.synchronize { db.key?(k) } }
  skip = File.exist?(BACK_SKIP) ? (JSON.parse(File.read(BACK_SKIP, encoding: 'UTF-8')) rescue {}) : {}
  skip.reject! { |_, (t, _)| t.to_i < since - 10 * 86_400 }
  old_tag = YEAR_ARCH ? 'old-y' : 'old'
  skipped = ->(k) { mx.synchronize { (w = skip[k] && skip[k][1]) == 'old' && YEAR_ARCH ? nil : w } }
  drop = ->(k, why) { mx.synchronize { skip[k] = [now, why] } }
  add = lambda do |rec, d, photo|
    Store.save_details(rec['key'], trim(d['details'] || []))
    rec['photo'] = Store.save_photo(photo, rec['key'], Src::UA, *(YEAR_ARCH ? YEAR_PH : []))
    rec['pics'] = rec['pics'].first(YEAR_PICS) if YEAR_ARCH && rec['pics']
    mx.synchronize do
      db[rec['key']] = rec
      stat['архив площадок: добавлено'] += 1
      pstat[rec['platform']]['backfill'] += 1
    end
  end
  since_of = ->(plat) { [since, now - ARCH_DAYS.fetch(plat, BACK_DAYS) * 86_400].max }
  vl_back = lambda do |plat, left|
    sn = since_of.(plat)
    old = 0
    Src.vl_archive(plat).each do |c|
      break if left.zero? || Time.now > stop || old >= 30
      next if known.(c['key'])
      case skipped.(c['key'])
      when 'old', 'old-y' then old += 1; next
      when nil then nil
      else next
      end
      sleep 1
      html = Src.get(c['url']) or next
      d = Src.vl_detail(plat, html)
      next drop.(c['key'], 'none') if d.nil? || d['skip']
      if (d['torg'] || d['req_to']).to_i < sn
        old += 1
        next drop.(c['key'], old_tag)
      end
      old = 0
      next if YEAR_ARCH && d['sec'] == 'oborud'
      r = Res.vl_result(html)
      next if r['st'] == 'pending'
      next drop.(c['key'], 'min') unless back_min_ok?(d['sec'], r['start'] || d['price_byn'])
      c['name'] ||= d['name']
      add.(back_rec(c, d['sec'], d, r, "#{plat} архив", now), d, [d['photo_url'], c['thumb']])
      left -= 1
    end
  end
  jm_back = lambda do |plat, left|
    sn = since_of.(plat)
    old = 0
    (Src.jm_list(plat) || []).each do |c|
      break if left.zero? || Time.now > stop || old >= 10
      next if c['status'] =~ /Предстоящ|Прием|Идут/ || known.(c['key']) || (YEAR_ARCH && c['sec'] == 'oborud')
      case skipped.(c['key'])
      when 'old', 'old-y' then old += 1; next
      when nil then nil
      else next
      end
      sleep 1
      html = Src.get(c['url']) or next
      d = Src.jm_detail(plat, html) or next
      if (d['torg'] || d['req_to']).to_i < sn
        old += 1
        next drop.(c['key'], old_tag)
      end
      old = 0
      r = Res.jm_result(html)
      next if r['st'] == 'pending'
      next drop.(c['key'], 'min') unless back_min_ok?(c['sec'], r['start'] || c['price'])
      add.(back_rec(c, c['sec'], d, r, "#{plat} архив", now), d, [d['photo_url'], c['thumb']])
      left -= 1
    end
  end
  jobs = {
    'bankrot-torg.by' => ->(left) { vl_back.('bankrot-torg.by', left) },
    'specrealization.by' => ->(left) { vl_back.('specrealization.by', left) },
    'expert-torgi.by' => ->(left) { jm_back.('expert-torgi.by', left) },
    'realtorgi.by' => ->(left) { jm_back.('realtorgi.by', left) },
    'torgi.gov.by' => lambda do |left|
      Src.tg_done(since_of.('torgi.gov.by')).each do |c|
        break if left.zero? || Time.now > stop
        next if known.(c['key']) || skipped.(c['key']) || (YEAR_ARCH && c['sec'] == 'oborud')
        next drop.(c['key'], 'min') unless back_min_ok?(c['sec'], c['price'])
        a = Src.tg_json("/auctions/#{c['auc']}/lot/#{c['art']}/public")
        sleep 3
        next unless a
        r = Res.tg_result(a, c['art'])
        next if r['st'] == 'pending'
        d = Src.tg_detail(c, a)
        add.(back_rec(c, c['sec'], d, r, 'torgi.gov.by архив', now), d, [d['photo_url']])
        left -= 1
      end
    end,
    'etpvit.by' => lambda do |left|
      Src.ev_list(since_of.('etpvit.by')).each do |c|
        break if left.zero? || Time.now > stop
        next if known.(c['key']) || skipped.(c['key']) || !c['eid'] || (YEAR_ARCH && c['sec'] == 'oborud')
        sleep 1
        info = Res.ea_info(c['eid'], Src::EV)
        r = Res.ea_result(info) or next
        next if r['st'] == 'pending'
        next drop.(c['key'], 'min') unless back_min_ok?(c['sec'], r['start'] || c['price'])
        html = Src.get(c['url']) or next
        d = Src.ev_detail(html) or next
        rec = back_rec(c, c['sec'], d, r, 'etpvit.by архив', now)
        rec['eid'] = c['eid']
        rec['torg'] = Res.ea_torg(info) || rec['torg']
        add.(rec, d, [d['photo_url'], c['thumb']])
        left -= 1
      end
    end,
    'iintorgi.by' => lambda do |left|
      Src.ii_done(since_of.('iintorgi.by')).each do |c, x|
        break if left.zero? || Time.now > stop
        next if known.(c['key']) || skipped.(c['key']) || (YEAR_ARCH && c['sec'] == 'oborud')
        r = Res.ii_result(x)
        next if r['st'] == 'pending'
        next drop.(c['key'], 'min') unless back_min_ok?(c['sec'], r['start'] || c['price'])
        add.(back_rec(c, c['sec'], c['d'], r, 'iintorgi.by архив', now), c['d'], [c['d']['photo_url']])
        left -= 1
      end
    end,
    'e-auction.by' => lambda do |left|
      PLAN['e-auction.by'].each do |path, sec|
        break if left.zero? || Time.now > stop
        next if YEAR_ARCH && sec == 'oborud'
        Src.ea_list(path, since: since).each do |c|
          break if left.zero? || Time.now > stop
          next if known.(c['key']) || skipped.(c['key']) || !c['eid']
          info = Res.ea_info(c['eid'])
          r = Res.ea_result(info) or next
          next drop.(c['key'], 'min') unless back_min_ok?(sec, r['start'])
          html = Src.get(c['url']) or next
          d = Src.ea_detail(html)
          rec = back_rec(c, sec, d, r, "e-auction.by #{path}", now)
          rec['eid'] = c['eid']
          rec['torg'] = Res.ea_torg(info) || rec['torg']
          add.(rec, d, [d['photo_url'], c['thumb']])
          left -= 1
          sleep 0.4
        end
      end
    end,
    'ipmtorgi.by' => lambda do |left|
      PLAN['ipmtorgi.by'].each do |path, sec0|
        break if left.zero? || Time.now > stop
        next if YEAR_ARCH && sec0 == 'oborud'
        Src.ipm_list(path, since: since).each do |c|
          break if left.zero? || Time.now > stop
          next if known.(c['key']) || skipped.(c['key'])
          sec = sec0 || ipm_kind(c['name'])
          html = Src.get(c['url']) or next
          all = Res.ipm_all_bids(html)
          r = Res.ipm_result(html, all)
          next drop.(c['key'], 'min') unless back_min_ok?(sec, r['start'] || c['price'])
          d = Src.ipm_detail(html)
          add.(back_rec(c, sec, d, r, "ipmtorgi.by #{path}", now), d, [d['photo_url'], c['thumb']])
          left -= 1
          sleep 0.4
        end
      end
    end,
    'beltorgi.by' => lambda do |left|
      PLAN['beltorgi.by'].each do |slug, sec|
        break if left.zero? || Time.now > stop
        next if YEAR_ARCH && sec == 'oborud'
        Src::BT_DONE.each_value do |status|
          old = 0
          (1..30).each do |p|
            cards = Src.bt_page(slug, p, status) or break
            cards.each do |c|
              break if left.zero? || Time.now > stop || old >= 5
              next if known.(c['key'])
              case skipped.(c['key'])
              when 'old', 'old-y' then old += 1; next
              when 'min' then next
              end
              html = Src.get(c['url']) or next
              r = Res.bt_result(html) or next
              d = Src.bt_detail(html)
              when_ = r['at'] || d['torg'] || d['req_to']
              if when_.to_i < since
                old += 1
                drop.(c['key'], old_tag)
                next
              end
              old = 0
              next drop.(c['key'], 'min') unless back_min_ok?(sec, r['start'])
              c['price'] = r['start'] if r['start'].to_f.positive?
              add.(back_rec(c, sec, d, r, "beltorgi.by #{slug}", now), d, [c['thumb']])
              left -= 1
              sleep 0.4
            end
            break if cards.size < 80 || left.zero? || Time.now > stop || old >= 5
            sleep 0.6
          end
        end
      end
    end,
    'belauction.by' => lambda do |left|
      Src.ba_list(:done).each do |c|
        break if left.zero? || Time.now > stop
        next if known.(c['key']) || skipped.(c['key'])
        next drop.(c['key'], old_tag) if c['closed_day'].to_i < since
        sleep 2
        html = Src.get(c['url']) or next
        r = Res.ba_result(html)
        next drop.(c['key'], 'min') unless back_min_ok?(c['sec'], r['price'] || c['price'])
        d = Src.ba_detail(html)
        add.(back_rec(c, c['sec'], d, r, 'belauction.by архив', now), d, [d['photo_url'], c['thumb']])
        left -= 1
      end
    end,
    'minskestate.by' => lambda do |left|
      Src.me_list.each do |c|
        break if left.zero? || Time.now > stop
        next if c['status'] !~ /Продан|не состоял|Отмен/i || known.(c['key']) || skipped.(c['key'])
        next drop.(c['key'], old_tag) if c['day'].to_i < since
        sleep 1
        html = Src.get(c['url']) or next
        r = Res.me_result(html)
        next if r['st'] == 'pending'
        sec = c['sec'] || ipm_kind(c['name'])
        next if YEAR_ARCH && sec == 'oborud'
        next drop.(c['key'], 'min') unless back_min_ok?(sec, r['start'] || c['price'])
        d = Src.me_detail(html)
        add.(back_rec(c, sec, d, r, 'minskestate.by архив', now), d, [])
        left -= 1
      end
    end,
    'auction24.by' => lambda do |left|
      Src.a24_done(since).each do |c|
        break if left.zero? || Time.now > stop
        next if known.(c['key']) || skipped.(c['key']) || (YEAR_ARCH && c['sec'] == 'oborud')
        sleep 1
        html = Src.get(c['url']) or next
        r = Res.a24_result(html)
        next if r['st'] == 'pending'
        next drop.(c['key'], 'min') unless back_min_ok?(c['sec'], r['start'] || c['price'])
        d = Src.a24_detail(html)
        add.(back_rec(c, c['sec'], d, r, 'auction24.by архив', now), d, [d['photo_url'], c['thumb']])
        left -= 1
      end
    end,
    'lotsale.by' => lambda do |left|
      Src.ls_done(since).each do |id|
        break if left.zero? || Time.now > stop
        key = "ls-#{id}"
        next if known.(key) || skipped.(key)
        sleep 0.5
        d = Src.ls_lot(id) or next
        next if YEAR_ARCH && d['sec'] == 'oborud'
        r = Res.ls_result(d['a'])
        next if r['st'] == 'pending'
        next drop.(key, 'min') unless back_min_ok?(d['sec'], r['start'] || d['price_byn'])
        c = Src.ls_card({ 'id' => id, 'lotName' => d['name'], 'price' => d['price_byn'],
                          'applicationDeadlineOnUtc' => d['a']['applicationDeadlineOnUtc'] }, d)
        add.(back_rec(c, d['sec'], d, r, 'lotsale.by архив', now), d, [d['photo_url']])
        left -= 1
      end
    end,
    'butb.by' => lambda do |left|
      Src.bu_done(since, stop).each do |c|
        break if left.zero? || Time.now > stop
        next if known.(c['key']) || skipped.(c['key']) || c['status'] !~ /состоявш|результативн|отмен|продан/i
        sleep 1
        html = Src.get(c['url']) or next
        r = Res.bu_result(html)
        next if r['st'] == 'pending'
        d = Src.bu_detail(html)
        next if YEAR_ARCH && d['sec'] == 'oborud'
        next drop.(c['key'], 'min') unless back_min_ok?(d['sec'], r['start'] || c['price'])
        c['name'] = d['name'] unless d['name'].to_s.empty?
        c['req_to'] ||= d['torg'] || c['day']
        add.(back_rec(c, d['sec'], d, r, 'butb.by архив', now), d, [d['photo_url'], c['thumb']])
        left -= 1
      end
    end,
    'konfiskat.by' => lambda do |left|
      arts = mx.synchronize { db.values.select { |l| l['platform'] == 'konfiskat.by' }.to_h { |l| [l['art'].to_s, l] } }
      tks = mx.synchronize { db.values.map { |l| l['tk'].to_s[%r{/(\d+)/?\z}, 1] }.compact.to_h { |a| [a, true] } }
      Src.tk_archive(YEAR_ARCH ? [since, now - YEAR_KF_DAYS * 86_400].max : since, stop).each do |c|
        break if left.zero? || Time.now > stop
        key = "kf-tk#{c['tk_id']}"
        next if tks[c['tk_id']] || known.(key) || skipped.(key)
        sleep 1
        html = Src.get(c['url']) or next
        d = Src.tk_detail(html)
        if (mine = arts[d['art'].to_s])
          mx.synchronize { mine['tk'] ||= c['url'] }
          next drop.(key, 'known')
        end
        r = Res.tk_result(html)
        rows = (d['details'].first || { 'rows' => [] })['rows']
        type = (rows.assoc('Тип транспорта') || [])[1].to_s
        sec = type =~ /груз|автобус|прицеп|тягач|специальн/i ? 'gruz' : kf_kind(d['title'].to_s + ' ' + c['name'])
        next drop.(key, 'min') unless back_min_ok?(sec, r['start'])
        store = (rows.assoc('Описание') || [])[1].to_s[/На хран\S*:?\s*(.+?)(?:\s+Осмотр|\z)/, 1]
        loc = store && region_of(store) =~ /обл|Минск/ ? store.sub(/\A.*?\s[-–]\s/, '')[0, 160] : nil
        day = c['day'].to_i
        req = Time.at(day - 86_400).then { |t| Time.local(t.year, t.month, t.day, 12, 0).to_i }
        price = r['start'].to_f.positive? ? r['start'] : c['price']
        rec = { 'key' => key, 'status' => 'archive', 'src' => 'konfiskat.by torgikonfiskat', 'last_seen' => now, 'bf' => now,
                'art' => d['art'] || c['tk_id'], 'name' => d['title'].to_s.empty? ? c['name'] : d['title'],
                'price' => price, 'prices' => [[req, price]], 'req_to' => req, 'torg' => day, 'url' => c['url'], 'tk' => c['url'],
                'location' => loc, 'region' => loc && region_of(loc), 'debtor' => 'Конфискованное имущество',
                'platform' => 'konfiskat.by', 'section' => sec, 'section_ru' => SEC_RU[sec], 'terms' => {},
                'closed' => req, 'why' => 'deadline', 'result' => r.merge('checked' => now, 'tries' => 1), 'pics' => d['photos'] || [] }
        add.(rec, d, [d['photo_url'], c['thumb']])
        left -= 1
      end
    end
  }
  done = year_done
  jobs.select! { |plat, _| year_left.include?(plat) } if YEAR_ARCH
  jobs.reject { |plat, _| PLAT_OFF.include?(plat) }.map do |plat, job|
    Thread.new do
      job.call(BACK_CAP)
      if YEAR_ARCH && Time.now < stop && pstat[plat]['backfill'] < BACK_CAP
        mx.synchronize { done[plat] = now }
        STDERR.puts "архив площадки #{plat} за год загружен"
      end
    rescue StandardError => e
      STDERR.puts "архив площадки #{plat}: ошибка #{e.message}"
    end
  end.each(&:join)
  File.write(BACK_SKIP, JSON.generate(skip))
  File.write(YEAR_DONE, JSON.generate(done)) if YEAR_ARCH
  STDERR.puts "архив площадок за #{BACK_DAYS} дн.: добавлено #{stat['архив площадок: добавлено']}" \
              "#{Time.now > stop ? ' (время прогона вышло — остальное в следующий раз)' : ''}"
end
