# encoding: utf-8

BIG_CAP = (ENV['BIG_CAP'] || 300).to_i
BIG_MIN = (ENV['BIG_MIN'] || 8).to_f
BIG_HARD = %w[konfiskat.by e-auction.by butb.by torgi.gov.by gostorg.by expert-torgi.by belauction.by].freeze
BIG_PAGE = %w[butb.by torgi.gov.by].freeze

def fill_big(db, stat, now)
  stop = Time.now + BIG_MIN * 60
  todo = db.values.select do |l|
    next false unless l['photo'] && !l['pb'] && l['pb_try'].to_i < 2 && BIG_SECS.include?(l['section']) && !PLAT_OFF.include?(l['platform'])
    l['status'] == 'active' ||
      (l['status'] == 'archive' && BIG_HARD.include?(l['platform']) && now - (l['closed'] || l['req_to']).to_i <= 90 * 86_400)
  end
  todo = todo.sort_by { |l| [l['status'] == 'active' ? 0 : 1, -(l['closed'] || l['req_to']).to_i] }.first(BIG_CAP)
  return if todo.empty?
  mx = Mutex.new
  todo.group_by { |l| l['platform'] }.map do |plat, ls|
    Thread.new do
      dead = 0
      ls.each do |l|
        break if Time.now > stop || dead >= 2
        t1 = Time.now
        urls = BIG_PAGE.include?(plat) ? [] : [Array(l['pics']).first]
        pb = urls.compact.any? && Store.save_big(urls, Src::UA)
        unless pb
          d = (fetch_detail(l) rescue nil)
          pb = d && Store.save_big([d['photo_url'], *Array(d['photos']).first(2)], Src::UA)
        end
        dead = !pb && Time.now - t1 > 60 ? dead + 1 : 0
        mx.synchronize do
          if pb
            l['pb'] = pb
            l.delete('pb_try')
            stat['большие фото: дозаполнено'] += 1
          else
            l['pb_try'] = l['pb_try'].to_i + 1
          end
        end
        sleep PICS_PAUSE[plat] || 0.5
      end
    rescue StandardError => e
      STDERR.puts "большие фото #{plat}: ошибка #{e.message}"
    end
  end.each(&:join)
  left = db.values.count { |l| l['photo'] && !l['pb'] && l['pb_try'].to_i < 2 && BIG_SECS.include?(l['section']) && l['status'] == 'active' }
  STDERR.puts "большие фото: дозаполнено #{stat['большие фото: дозаполнено']}, активных без большого фото осталось #{left}"
end
