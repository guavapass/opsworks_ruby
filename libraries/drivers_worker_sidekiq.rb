# frozen_string_literal: true
module Drivers
  module Worker
    class Sidekiq < Drivers::Worker::Base
      adapter :sidekiq
      allowed_engines :sidekiq
      output filter: [:config, :process_count, :require, :syslog]

      def configure(context)
        add_sidekiq_config(context)
        add_sidekiq_monit(context)
      end

      def before_deploy(context)
        deploy_to = deploy_dir(app)
        env = { 'USER' => node['deployer']['user'] }

        (1..process_count).each do |process_number|
          pid_file = pid_file(process_number)
          service_name = sidekiq_service_name(process_number)

          context.execute "unmonitor #{service_name}" do
            command "monit unmonitor #{service_name}"
            notifies :run, "execute[quiet #{service_name}]", :immediately
          end

          context.execute "quiet #{service_name}" do
            action :nothing
            cwd File.join(deploy_to, 'current')
            command "bundle exec sidekiqctl quiet #{pid_file}"
            user node['deployer']['user']
            group www_group
            environment env

            only_if { File.exists?(pid_file) }
          end
        end
      end

      def after_deploy(context)
        deploy_to = deploy_dir(app)
        (1..process_count).each do |process_number|
          env = { 'USER' => node['deployer']['user'] }
          service_name = sidekiq_service_name(process_number)
          start_command = start_sidekiq_command(process_number)
          stop_command = stop_sidekiq_command(process_number)


          context.execute "stop #{service_name}" do
            cwd File.join(deploy_to, 'current')
            user node['deployer']['user']
            group www_group
            environment env
            command stop_command
            notifies :run, "execute[restart #{service_name}]", :immediately
          end

          context.execute "restart #{service_name}" do
            action :nothing
            cwd File.join(deploy_to, 'current')
            user node['deployer']['user']
            group www_group
            environment env
            command start_command
            notifies :run, "execute[monitor #{service_name}]", :immediately
          end

          context.execute "monitor #{service_name}" do
            action :nothing
            command "monit monitor #{service_name}"
          end

        end
      end
      alias after_undeploy after_deploy

      private

      def start_sidekiq_command(process_number)
        deploy_to = deploy_dir(app)
        pid_file = pid_file(process_number)
        config_file = File.join(deploy_to, 'shared','config', config_file(process_number))
        log_file = File.join(deploy_to, 'shared', 'log', "#{sidekiq_service_name(process_number)}.log")
        rails_env = node['deploy'][app['shortname']]['environment']

        args = ["--index #{process_number}"]
        args.push "--pidfile #{pid_file}"
        args.push "--environment #{rails_env}"
        args.push "--config #{config_file}"
        args.push "--require #{File.join(deploy_to, 'current', out[:require])}" if out[:require].present?
        args.push "--logfile #{log_file}"
        args.push '--daemon'

        "bundle exec sidekiq RAILS_ENV=#{rails_env} #{args.compact.join(' ')}"
      end

      def stop_sidekiq_command(process_number)
        "bundle exec sidekiqctl stop #{pid_file(process_number)} 60"
      end



      def add_sidekiq_config(context)
        deploy_to = deploy_dir(app)
        each_process_with_config do |process_number, process_config|
          context.template File.join(deploy_to, config_file(process_number)) do
            owner node['deployer']['user']
            group www_group
            source 'sidekiq.conf.yml.erb'
            variables config: process_config
          end
        end
      end

      def pid_file(process_number)
        "#{deploy_dir(app)}/shared/pids/#{sidekiq_service_name(process_number)}.pid"
      end

      def config_file(process_number)
        File.join('shared', 'config', "#{sidekiq_service_name(process_number)}.yml")
      end

      def sidekiq_service_name(process_number)
        "sidekiq_#{app['shortname']}-#{process_number}"
      end

      def each_process_with_config
        configs = Array.wrap(configuration)

        (1..process_count).each do |process_number|
          process_config = configs.count > 1 ? configs[process_number - 1] : configs[0]
          yield(process_number, process_config)
        end
      end

      def add_sidekiq_monit(context)
        app_shortname = app['shortname']
        deploy_to = deploy_dir(app)
        output = out
        env = environment

        context.template File.join(node['monit']['basedir'], "sidekiq_#{app_shortname}.monitrc") do
          mode '0640'
          source 'sidekiq.monitrc.erb'
          variables application: app_shortname, out: output, deploy_to: deploy_to, environment: env
        end
        context.execute 'monit reload'
      end

      def process_count
        [out[:process_count].to_i, 1].max
      end

      def environment
        framework = Drivers::Framework::Factory.build(app, node)
        app['environment'].merge(framework.out[:deploy_environment] || {})
      end

      def configuration
        JSON.parse(out[:config].to_json, symbolize_names: true)
      end
    end
  end
end
