#!/usr/bin/env ruby
require 'bundler'
Bundler.require

require 'time'
require 'pp'
require 'dedupe'

Trello.configure do |config|
  config.developer_public_key = ENV['TRELLO_OAUTH_PUBLIC_KEY']
  config.member_token = ENV['TRELLO_TOKEN']
end

class Bot

  def self.run

    hipchat = HipChat::Client.new(ENV['HIPCHAT_API_TOKEN'])

    dedupe = Dedupe.new

    hipchat_rooms = ENV['HIPCHAT_ROOM'].split(',')
    label_filters = ENV['TRELLO_FILTER'].split(',')
    boards = ENV['TRELLO_BOARD'].split(',').each_with_index.map {|board, i|
      {
        board: Trello::Board.find(board),
        room: hipchat_rooms[i],
        label_filter: label_filters[i].split('.')
      }
    }

    now = Time.now.utc
    timestamps = {}

    boards.each do |board_with_room|
      timestamps[board_with_room[:board].id] = now
    end

    scheduler = Rufus::Scheduler.new

    scheduler.every '5s' do
      puts "Querying Trello at #{Time.now.to_s}"
      boards.each do |board_monitor|
        board = board_monitor[:board]
        hipchat_room = hipchat[board_monitor[:room]]
        last_timestamp = timestamps[board.id]
        actions = board.actions(:filter => :all, :since => last_timestamp.iso8601)
        actions.each do |action|
          if last_timestamp < action.date
            label_filter = board_monitor[:label_filter]
            if label_filter.first != '*'
              if action.attributes[:data]['card']
                card_colors = Trello::Card.find(action.attributes[:data]['card']['id']).labels.map do |label|
                  label.attributes[:color]
                end
                puts action.inspect
                if (label_filter & card_colors).empty?
                  puts 'Card does not fit filter'
                  next
                else
                  puts 'Card fits filter'
                end
              end
            end
            board_link = "<a href='https://trello.com/board/#{action.data['board']['id']}'>#{action.data['board']['name']}</a>"
            begin
              card_link = "#{board_link} : <a href='https://trello.com/card/#{action.data['board']['id']}/#{action.data['card']['idShort']}'>#{action .data['card']['name']}</a>"
            rescue Exception
              puts 'Card link unable to be constructed. Skipping action.'
              next
            end
            message = case action.type.to_sym
            when :updateCard
                if action.data['listBefore']
                  "#{action.member_creator.full_name} moved #{card_link} from #{action.data['listBefore']['name']} to #{action.data['listAfter']['name']}"
                else
                  ''
                end
            when :createCard
              "#{action.member_creator.full_name} added #{card_link} to #{action.data['list']['name']}"
            when :moveCardToBoard
              "#{action.member_creator.full_name} moved #{card_link} from the #{action.data['boardSource']['name']} board to #{action.data['board']['name']}"
            when :updateCheckItemStateOnCard
              if action.data['checkItem']['state'] == 'complete'
                "#{action.member_creator.full_name} checked off \"#{ action.data['checkItem']['name']}\" on #{card_link}"
              else
                "#{action.member_creator.full_name} unchecked off \"#{action.data['checkItem']['name']}\" to #{card_link}"
              end
            when :commentCard
              comment_text = action.data['text']
              if comment_text.size > 140
                comment_text = comment_text[0..140] + '...'
              end
              "#{action.member_creator.full_name} commented on #{card_link}: #{comment_text}"
            when :addAttachmentToCard
              "#{action.member_creator.full_name} attached \"#{ action.data['attachment']['name']}\" to #{card_link}"
            else
              STDERR.puts action.inspect
              ''
            end

            if message.blank?
              puts 'No case statement for this event'
            else
              if dedupe.new?(hipchat_room.room_id + message)
                puts "Sending: #{message}"
                hipchat_room.send('Trello', message, :color => :purple)
              else
                puts "Supressing duplicate message: #{message}"
              end
            end
          end
        end
        timestamps[board.id] = actions.first.date if actions.length > 0
      end
    end

    scheduler.join
  end

end

if __FILE__ == $0
  Bot.run
end

