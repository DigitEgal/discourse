# frozen_string_literal: true

require 'mysql2'
require 'htmlentities'
require File.expand_path(File.dirname(__FILE__) + '/base.rb')

class ImportScripts::Drupal < ImportScripts::Base
  DRUPAL_DB = ENV['DRUPAL_DB'] || 'drupal'
  BATCH_SIZE = 1000

  ATTACHMENT_DIR = '/root/files/upload'

  CATEGORY_ID = ENV['CATEGORY_ID'] || 1

  # Flag IDs
  BOOKMARK_ID = ENV['BOOKMARK_ID'] || 1
  SUBSCRIBE_ID = ENV['SUBSCRIBE_ID'] || 2
  LIKE_COMMENT_ID = ENV['LIKE_COMMENT_ID'] || 4
  LIKE_NODE_ID = ENV['LIKE_NODE_ID'] || 5

  def initialize
    super

    @htmlentities = HTMLEntities.new

    @client = Mysql2::Client.new(
      host: 'localhost',
      username: 'root',
      # password: 'password',
      database: DRUPAL_DB
    )

    @last_invalid_user_id = 0

    @import_categories = []
    @topics_to_category = {}
    @nodes_to_category = {}

    ARGV.each do |arg|
      key, value = arg.split('=')
      case key.strip.downcase
      when 'import_categories'
        @import_categories = value.split(',').to_set
      when 'topics_to_category'
        category_name, topics_list = value.split(',')
        File.readlines(topics_list).each do |topic|
          @topics_to_category[topic.strip] = category_name
        end
      end
    end
  end

  def execute
    resolve_url_alias

    import_users
    import_muted_users
    import_sso_records
    import_gravatars if ENV['DRUPAL_IMPORT_GRAVATAR']

    import_categories if !ENV['DRUPAL_SKIP_CATEGORIES']

    # "Nodes" in Drupal are divided into types. Here we import two types,
    # and will later import all the comments/replies for each node.
    # You will need to figure out what the type names are on your install and edit the queries to match.
    import_blog_topics if ENV['DRUPAL_IMPORT_BLOG']

    import_topics
    import_posts
    import_private_messages
    import_attachments
    mark_topics_as_solved
    postprocess_posts if ENV['DRUPAL_POSTPROCESS_POSTS']
    import_subscriptions
    import_likes
    import_bookmarks

    create_permalinks
  end

  def resolve_url_alias
    @topics_to_category.each do |topic_url, category|
      results = mysql_query(<<~SQL).to_a
        SELECT source
        FROM url_alias
        WHERE alias = '#{CGI.unescape(topic_url).gsub('\'', '\\\'')}'
        LIMIT 1
      SQL

      if results.empty?
        next puts "cannot find alias for #{topic_url}"
      end

      node_id = results.first['source'].gsub('node/', '')

      @nodes_to_category[node_id] = category
    end
  end

  def import_users
    puts '', 'importing users'

    total_count = mysql_query(<<~SQL).first['count']
      SELECT COUNT(uid) count
      FROM users
    SQL

    last_user_id = -1

    batches(BATCH_SIZE) do |offset|
      users = mysql_query(<<-SQL).to_a
        SELECT uid,
               name username,
               mail email,
               created,
               status
        FROM users
        WHERE uid > #{last_user_id}
        ORDER BY uid
        LIMIT #{BATCH_SIZE}
      SQL

      break if users.empty?
      last_user_id = users[-1]['uid']
      users.reject! { |u| @lookup.user_already_imported?(u['uid']) }

      create_users(users, total: total_count, offset: offset) do |user|
        username = @htmlentities.decode(user['username']).strip

        email = user['email'].presence || ''
        unless email[EmailValidator.email_regex]
          @last_invalid_user_id = @last_invalid_user_id + 1
          email = @last_invalid_user_id > 1 ? "invalid_user_#{@last_invalid_user_id}@email.invalid"
                                            : "invalid_user@email.invalid"
        end

        {
          id: user['uid'],
          name: username,
          email: email,
          created_at: Time.zone.at(user['created']),
          suspended_at: user['status'].to_i == 0 ? Time.zone.now : nil,
          suspended_till: user['status'].to_i == 0 ? 100.years.from_now : nil
        }
      end
    end
  end

  def import_categories
    # You'll need to edit the following query for your Drupal install:
    #
    #   * Drupal allows duplicate category names, so you may need to exclude some categories or rename them here.
    #   * Table name may be term_data.
    #   * May need to select a vid other than 1

    puts '', 'importing categories'

    categories = mysql_query(<<-SQL).to_a
      SELECT tid,
             name,
             description
      FROM taxonomy_term_data
      WHERE vid = #{CATEGORY_ID}
    SQL

    create_categories(categories) do |category|
      {
        id: category['tid'],
        name: @htmlentities.decode(category['name']).strip,
        description: @htmlentities.decode(category['description']).strip
      }
    end

    create_categories(@topics_to_category.values.uniq) do |category_name|
      {
        id: category_name,
        name: category_name
      }
    end
  end

  def import_blog_topics
    puts '', 'importing blog topics'

    unless Category.find_by_name('Blog')
      create_category(
        {
          name: 'Blog',
          description: 'Articles from the blog'
        },
        nil
      )
    end

    category_id = Category.find_by_name('Blog').id

    blogs = mysql_query(<<-SQL).to_a
      SELECT n.nid nid,
             n.title title,
             n.uid uid,
             n.created created,
             n.sticky sticky,
             f.body_value body
      FROM node n,
           field_data_body f
      WHERE n.type = 'article'
        AND n.nid = f.entity_id
        AND n.status = 1
    SQL

    create_posts(blogs) do |topic|
      {
        id: "nid:#{topic['nid']}",
        user_id: user_id_from_imported_user_id(topic['uid']) || -1,
        category: category_id,
        raw: topic['body'],
        created_at: Time.zone.at(topic['created']),
        pinned_at: topic['sticky'].to_i == 1 ? Time.zone.at(topic['created']) : nil,
        title: topic['title'].try(:strip),
        custom_fields: { import_id: "nid:#{topic['nid']}" }
      }
    end
  end

  def import_topics
    puts '', 'importing forum topics'

    total_count = mysql_query(<<-SQL).first['count']
      SELECT COUNT(*) count
      FROM forum_index fi,
           node n
      WHERE n.type = 'forum'
        AND fi.nid = n.nid
        AND n.status = 1
    SQL

    batches(BATCH_SIZE) do |offset|
      results = mysql_query(<<-SQL).to_a
        SELECT fi.nid nid,
               fi.title title,
               fi.tid tid,
               n.uid uid,
               fi.created created,
               fi.sticky sticky,
               f.body_value body,
               nc.totalcount views,
               n.status status,
               n.comment comment,
               fl.timestamp solved
        FROM forum_index fi
        LEFT JOIN node n ON fi.nid = n.nid
        LEFT JOIN field_data_body f ON f.entity_id = n.nid
        LEFT JOIN flagging fl ON fl.entity_id = n.nid AND fl.fid = 7
        LEFT JOIN node_counter nc ON nc.nid = n.nid
        WHERE n.type = 'forum'
        LIMIT #{BATCH_SIZE}
        OFFSET #{offset};
      SQL

      break if results.size < 1
      next if all_records_exist? :posts, results.map { |p| "nid:#{p['nid']}" }

      create_posts(results, total: total_count, offset: offset) do |row|
        begin
          if @nodes_to_category[row['nid'].to_s].present?
            category_id = @nodes_to_category[row['nid'].to_s]
          elsif @import_categories.include?(row['tid'].to_s)
            category_id = row['tid']
          else
            next # topic not mapped and category is not imported either
          end

          topic = {
            id: "nid:#{row['nid']}",
            user_id: user_id_from_imported_user_id(row['uid']) || -1,
            category: category_id_from_imported_category_id(category_id),
            raw: preprocess_raw(row['body']),
            created_at: Time.zone.at(row['created']),
            pinned_at: row['sticky'].to_i == 1 ? Time.zone.at(row['created']) : nil,
            title: row['title'].try(:strip),
            views: row['views'],
            visible: row['status'].to_i == 1,
            closed: row['comment'].to_i != 2
          }
          topic[:custom_fields] = { import_solved: true } if row['solved'].present?
          topic
        rescue => e
          warn "Failed to import topic: #{e.message}"
          warn "  row = #{row.inspect}"
        end
      end
    end
  end

  def import_posts
    puts '', 'creating replies in topics'

    total_count = mysql_query(<<-SQL).first['count']
      SELECT COUNT(*) count
      FROM comment c,
           node n
      WHERE n.nid = c.nid
        AND c.status = 1
        AND n.type IN ('article', 'forum')
        AND n.status = 1
    SQL

    batches(BATCH_SIZE) do |offset|
      results = mysql_query(<<-SQL).to_a
        SELECT c.cid,
               c.pid,
               c.nid,
               c.uid,
               c.created,
               f.comment_body_value body
        FROM comment c,
             field_data_comment_body f,
             node n
        WHERE c.cid = f.entity_id
          AND n.nid = c.nid
          AND c.status = 1
          AND n.type IN ('blog', 'forum')
          AND n.status = 1
        LIMIT #{BATCH_SIZE}
        OFFSET #{offset}
      SQL

      break if results.size < 1
      next if all_records_exist? :posts, results.map { |p| "cid:#{p['cid']}" }

      create_posts(results, total: total_count, offset: offset) do |row|
        begin
          topic_mapping = topic_lookup_from_imported_post_id("nid:#{row['nid']}")
          if topic_mapping && topic_id = topic_mapping[:topic_id]
            mapped = {
              id: "cid:#{row['cid']}",
              topic_id: topic_id,
              user_id: user_id_from_imported_user_id(row['uid']) || -1,
              raw: preprocess_raw(row['body']),
              created_at: Time.zone.at(row['created'])
            }

            if row['pid']
              parent = topic_lookup_from_imported_post_id("cid:#{row['pid']}")
              mapped[:reply_to_post_number] = parent[:post_number] if parent && parent[:post_number] > (1)
            end

            mapped
          else
            puts "No topic found for comment #{row['cid']}"
            nil
          end
        rescue => e
          warn "Failed to import reply: #{e.message}"
          warn "  row = #{row.inspect}"
        end
      end
    end
  end

  def import_private_messages
    puts '', 'importing private messages'

    puts '  building target users lookup table'

    target_user_ids = {}
    thread_id_to_topic_id = {}

    batches(BATCH_SIZE) do |offset|
      results = mysql_query(<<~SQL).to_a
        SELECT DISTINCT thread_id,
               recipient
        FROM pm_index
        LIMIT #{BATCH_SIZE}
        OFFSET #{offset}
      SQL

      break if results.size < 1

      results.each do |row|
        (target_user_ids[row['thread_id']] ||= []) << row['recipient']
      end
    end

    puts '  importing private posts'

    total_count = mysql_query(<<-SQL).first['count']
      SELECT COUNT(*) count
      FROM pm_message
      LEFT JOIN pm_index ON pm_index.mid = pm_message.mid
      WHERE pm_message.author = pm_index.recipient
    SQL

    batches(BATCH_SIZE) do |offset|
      results = mysql_query(<<-SQL).to_a
        SELECT pm_message.mid mid,
               pm_index.thread_id thread_id,
               pm_message.author author,
               pm_message.subject `subject`,
               pm_message.body body,
               pm_message.`timestamp` `timestamp`,
               pm_message.reply_to_mid reply_to_mid
        FROM pm_message
        LEFT JOIN pm_index ON pm_index.mid = pm_message.mid
        WHERE pm_message.author = pm_index.recipient
        LIMIT #{BATCH_SIZE}
        OFFSET #{offset}
      SQL

      break if results.size < 1
      next if all_records_exist? :posts, results.map { |p| "mid:#{p['mid']}" }

      create_posts(results, total: total_count, offset: offset) do |row|
        begin
          mapped = {
            id: "mid:#{row['mid']}",
            user_id: @lookup.user_id_from_imported_user_id(row['author']) || Discourse.system_user.id,
            created_at: Time.zone.at(row['timestamp']),
            raw: preprocess_raw(row['body'])
          }

          if thread_id_to_topic_id[row['thread_id']].blank?
            target_recipients = target_user_ids[row['thread_id']] || []
            target_recipients << row['author']
            target_recipients.uniq!
            target_recipients.map! { |user_id| @lookup.find_user_by_import_id(user_id).try(:username) }
            target_recipients.compact!

            mapped[:title] = row['subject'].try(:strip)
            mapped[:archetype] = Archetype.private_message
            mapped[:target_usernames] = target_recipients.join(',')

            mapped[:post_create_action] = proc do |post|
              thread_id_to_topic_id[row['thread_id']] = post.topic_id
            end
          else
            mapped[:topic_id] = thread_id_to_topic_id[row['thread_id']]
            raise 'no topic found for this PM' if mapped[:topic_id].blank?

            if row['reply_to_mid'] > 0
              post_id = post_id_from_imported_post_id("mid:#{row['reply_to_mid']}")
              if post = Post.find_by(id: post_id)
                mapped[:reply_to_post_number] = post.post_number
              end
            end
          end

          mapped
        rescue => e
          warn "Failed to import private message: #{e.message}"
          warn "  row = #{row.inspect}"
        end
      end
    end
  end

  def import_likes
    puts '', 'importing post likes'

    total_count = mysql_query(<<~SQL).first['count']
      SELECT COUNT(uid) count
      FROM flagging
      WHERE fid = #{LIKE_NODE_ID}
         OR fid = #{LIKE_COMMENT_ID}
    SQL
    count = 0

    batches(BATCH_SIZE) do |offset|
      rows = mysql_query(<<-SQL).to_a
        SELECT flagging_id,
               entity_type,
               entity_id,
               uid
        FROM flagging
        WHERE fid = #{LIKE_NODE_ID}
           OR fid = #{LIKE_COMMENT_ID}
        LIMIT #{BATCH_SIZE}
        OFFSET #{offset}
      SQL

      break if rows.empty?

      rows.each do |row|
        print_status(count += 1, total_count, get_start_time("likes"))

        identifier = row['entity_type'] == 'comment' ? 'cid' : 'nid'
        next unless user_id = user_id_from_imported_user_id(row['uid'])
        next unless post_id = post_id_from_imported_post_id("#{identifier}:#{row['entity_id']}")
        next unless user = User.find_by(id: user_id)
        next unless post = Post.find_by(id: post_id)

        begin
          PostActionCreator.like(user, post)
        rescue StandardError
          puts "cannot import like (user = #{row['uid']} / #{user_id}, post_id = #{identifier}:#{row['entity_id']} / #{post_id})"
        end
      end
    end
  end

  def import_bookmarks
    puts '', 'importing bookmarks'

    total_count = mysql_query(<<~SQL).first['count']
      SELECT COUNT(uid) count
      FROM flagging
      WHERE fid = #{BOOKMARK_ID}
    SQL
    count = 0

    batches(BATCH_SIZE) do |offset|
      rows = mysql_query(<<-SQL).to_a
        SELECT flagging_id,
               entity_type,
               entity_id,
               uid
          FROM flagging
         WHERE fid = #{BOOKMARK_ID}
         LIMIT #{BATCH_SIZE}
        OFFSET #{offset}
      SQL

      break if rows.empty?

      rows.each do |row|
        print_status(count += 1, total_count, get_start_time("bookmarks"))

        identifier = row['entity_type'] == 'comment' ? 'cid' : 'nid'
        next unless user_id = user_id_from_imported_user_id(row['uid'])
        next unless post_id = post_id_from_imported_post_id("#{identifier}:#{row['entity_id']}")
        next unless user = User.find_by(id: user_id)
        next unless post = Post.find_by(id: post_id)

        begin
          BookmarkManager.new(user).create(post_id: post.id)
        rescue StandardError
          puts "cannot import bookmark (user = #{row['uid']} / #{user_id}, post_id = #{identifier}:#{row['entity_id']} / #{post_id})"
        end
      end
    end
  end

  def import_subscriptions
    puts '', 'importing topic subscriptions...'

    total_count = mysql_query(<<~SQL).first['count']
      SELECT COUNT(uid) count
      FROM flagging
      WHERE fid = #{SUBSCRIBE_ID}
    SQL
    count = 0

    batches(BATCH_SIZE) do |offset|
      rows = mysql_query(<<-SQL).to_a
        SELECT flagging_id,
               entity_type,
               entity_id,
               uid
        FROM flagging
        WHERE fid = #{SUBSCRIBE_ID}
        LIMIT #{BATCH_SIZE}
        OFFSET #{offset}
      SQL

      break if rows.empty?

      rows.each do |row|
        print_status(count += 1, total_count, get_start_time("subscriptions"))

        identifier = row['entity_type'] == 'comment' ? 'cid' : 'nid'
        next unless user_id = user_id_from_imported_user_id(row['uid'])
        next unless post_id = post_id_from_imported_post_id("#{identifier}:#{row['entity_id']}")
        next unless user = User.find_by(id: user_id)
        next unless post = Post.find_by(id: post_id)

        begin
          TopicUser.change(user.id, post.topic_id, notification_level: NotificationLevels.all[:watching])
        rescue StandardError
          puts "cannot import subscription (user = #{row['uid']} / #{user_id}, post_id = #{identifier}:#{row['entity_id']} / #{post_id})"
        end

        begin
          BookmarkManager.new(user).create(post_id: post.id)
        rescue StandardError
          puts "cannot import subscription as bookmark (user = #{row['uid']} / #{user_id}, post_id = #{identifier}:#{row['entity_id']} / #{post_id})"
        end
      end
    end
  end

  def mark_topics_as_solved
    puts '', 'marking topics as solved'

    solved_topics = TopicCustomField.where(name: 'import_solved').where(value: true).pluck(:topic_id)

    solved_topics.each do |topic_id|
      next unless topic = Topic.find(topic_id)
      next unless post = topic.posts.last

      PostCustomField.create!(post_id: post.id, name: 'is_accepted_answer', value: true)
      TopicCustomField.create!(topic_id: topic_id, name: 'accepted_answer_post_id', value: post.id)
    end
  end

  def import_sso_records
    puts '', 'importing sso records'

    start_time = Time.now
    current_count = 0
    users = UserCustomField.where(name: 'import_id')
    total_count = users.count

    return if users.empty?

    users.each do |ids|
      user_id = ids.user_id
      external_id = ids.value
      next unless user = User.find(user_id)

      begin
        current_count += 1
        print_status(current_count, total_count, start_time)
        SingleSignOnRecord.create!(
          user_id: user.id,
          external_id: external_id,
          external_email: user.email,
          last_payload: ''
        )
      rescue StandardError
        next
      end
    end
  end

  def import_attachments
    puts '', 'importing attachments'

    current_count = 0
    success_count = 0
    fail_count = 0

    total_count = mysql_query(<<-SQL).first['count']
      SELECT COUNT(field_post_attachment_fid) count
      FROM field_data_field_post_attachment
    SQL

    batches(BATCH_SIZE) do |offset|
      attachments = mysql_query(<<-SQL).to_a
        SELECT *
        FROM field_data_field_post_attachment fp
        LEFT JOIN file_managed fm ON fp.field_post_attachment_fid = fm.fid
        LIMIT #{BATCH_SIZE}
        OFFSET #{offset}
      SQL

      break if attachments.size < 1

      attachments.each do |attachment|
        print_status(current_count += 1, total_count, get_start_time("attachments"))

        identifier = attachment['entity_type'] == 'comment' ? 'cid' : 'nid'
        next unless user_id = user_id_from_imported_user_id(attachment['uid'])
        next unless post_id = post_id_from_imported_post_id("#{identifier}:#{attachment['entity_id']}")
        next unless user = User.find(user_id)
        next unless post = Post.find(post_id)

        begin
          new_raw = post.raw.dup
          upload, filename = find_upload(post, attachment)

          unless upload
            fail_count += 1
            next
          end

          upload_html = html_for_upload(upload, filename)
          new_raw = "#{new_raw}\n\n#{upload_html}" unless new_raw.include?(upload_html)

          if new_raw != post.raw
            PostRevisor.new(post).revise!(
              post.user,
              { raw: new_raw },
              bypass_bump: true,
              edit_reason: 'Import attachment from Drupal'
            )
          else
            puts '', 'Skipped upload: already imported'
          end

          success_count += 1
        rescue => e
          puts e
        end
      end
    end
  end

  def create_permalinks
    puts '', 'creating permalinks...'

    Topic.listable_topics.find_each do |topic|
      begin
        tcf = topic.custom_fields
        if tcf && tcf['import_id']
          node_id = tcf['import_id'][/nid:(\d+)/, 1]
          slug = "/topic/#{node_id}"
          Permalink.find_or_create_by!(url: slug, topic_id: topic.id)
        end
      rescue => e
        puts e.message
        puts "Permalink creation failed for id #{topic.id}"
      end
    end

    puts '', 'creating permalinks from url_alias...'

    current_count = 0
    total_count = mysql_query(<<-SQL).first['count']
      SELECT COUNT(*) count
      FROM url_alias
    SQL

    batches(BATCH_SIZE) do |offset|
      aliases = mysql_query(<<-SQL).to_a
        SELECT source, alias
        FROM url_alias
        LIMIT #{BATCH_SIZE}
        OFFSET #{offset}
      SQL

      break if aliases.size < 1

      aliases.each do |row|
        print_status(current_count += 1, total_count, get_start_time("aliases"))

        entity_type, entity_id = row['source'].split('/')

        begin
          if entity_type == 'forum'
            category_id = category_id_from_imported_category_id(entity_id)
            Permalink.find_or_create_by!(url: row['alias'], category_id: category_id)
          elsif entity_type == 'node'
            topic_mapping = topic_lookup_from_imported_post_id("nid:#{entity_id}")
            if topic_mapping && topic_id = topic_mapping[:topic_id]
              Permalink.find_or_create_by!(url: row['alias'], topic_id: topic_id)
            end
          elsif entity_type == 'user'
            username = @lookup.find_username_by_import_id(entity_id)
            Permalink.find_or_create_by!(url: row['alias'], external_url: "/u/#{username}") if username.present?
          end
        rescue => e
          puts e
        end
      end
    end
  end

  def find_upload(post, attachment)
    uri = attachment['uri'][%r{public://upload/(.+)}, 1]
    real_filename = CGI.unescapeHTML(uri)
    file = File.join(ATTACHMENT_DIR, real_filename)

    unless File.exist?(file)
      puts "Attachment file #{attachment['filename']} doesn't exist"

      tmpfile = 'attachments_failed.txt'
      filename = File.join('/tmp/', tmpfile)
      File.open(filename, 'a') do |f|
        f.puts attachment['filename']
      end
    end

    upload = create_upload(post.user.id || -1, file, real_filename)

    if upload.nil? || upload.errors.any?
      puts 'Upload not valid'
      puts upload.errors.inspect if upload
      return
    end

    [upload, real_filename]
  end

  def preprocess_raw(raw)
    return if raw.blank?

    # quotes on new lines
    raw.gsub!(%r{\[quote\](.+?)\[/quote\]}im) do |quote|
      quote.gsub!(%r{\[quote\](.+?)\[/quote\]}im) { "\n#{Regexp.last_match(1)}\n" }
      quote.gsub!(/\n(.+?)/) { "\n> #{Regexp.last_match(1)}" }
    end

    # [QUOTE=<username>]...[/QUOTE]
    raw.gsub!(%r{\[quote=([^;\]]+)\](.+?)\[/quote\]}im) do
      username = Regexp.last_match(1)
      quote = Regexp.last_match(2)
      "\n[quote=\"#{username}\"]\n#{quote}\n[/quote]\n"
    end

    raw.strip!
    raw
  end

  def postprocess_posts
    puts '', 'postprocessing posts'

    current = 0
    total_count = Post.count

    Post.find_each do |post|
      print_status(current += 1, total_count, get_start_time("postprocess_posts"))

      begin
        raw = post.raw
        new_raw = raw.dup

        # replace old topic to new topic links
        new_raw.gsub!(%r{https://site.com/forum/topic/(\d+)}im) do
          post_id = post_id_from_imported_post_id("nid:#{Regexp.last_match(1)}")
          next unless post_id

          topic = Post.find(post_id).topic
          "https://community.site.com/t/-/#{topic.id}"
        end

        # replace old comment to reply links
        new_raw.gsub!(%r{https://site.com/comment/(\d+)#comment-\d+}im) do
          post_id = post_id_from_imported_post_id("cid:#{Regexp.last_match(1)}")
          next unless post_id

          post_ref = Post.find(post_id)
          "https://community.site.com/t/-/#{post_ref.topic_id}/#{post_ref.post_number}"
        end

        if raw != new_raw
          post.raw = new_raw
          post.save
        end
      rescue StandardError
        puts '', "Failed rewrite on post: #{post.id}"
      end
    end
  end

  def import_muted_users
    puts '', 'importing muted users'

    total_count = mysql_query(<<~SQL).first['count']
      SELECT COUNT(*) count
      FROM pm_block_user
    SQL
    count = 0

    batches(BATCH_SIZE) do |offset|
      rows = mysql_query(<<-SQL).to_a
        SELECT author, recipient
        FROM pm_block_user
        LIMIT #{BATCH_SIZE}
        OFFSET #{offset}
      SQL

      break if rows.empty?

      rows.each do |row|
        print_status(count += 1, total_count, get_start_time('muted'))

        next unless user_id = user_id_from_imported_user_id(row['recipient'])
        next unless muted_user_id = user_id_from_imported_user_id(row['author'])

        begin
          MutedUser.create(user_id: user_id, muted_user_id: muted_user_id)
        rescue StandardError
          nil
        end
      end
    end
  end

  def import_gravatars
    puts '', 'importing gravatars'

    current = 0
    total_count = User.count

    User.find_each do |user|
      print_status(current += 1, total_count, get_start_time("gravatars"))

      begin
        user.create_user_avatar(user_id: user.id) unless user.user_avatar
        user.user_avatar.update_gravatar!
      rescue StandardError
        puts '', 'Failed avatar update on user #{user.id}'
      end
    end
  end

  def parse_datetime(time)
    DateTime.strptime(time, '%s')
  end

  def mysql_query(sql)
    @client.query(sql, cache_rows: true)
  end
end

ImportScripts::Drupal.new.perform if __FILE__ == $0
