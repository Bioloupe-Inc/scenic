module Scenic
  module Adapters
    class Postgres
      class UpdateWithCascade
        def initialize(adapter:, name:, definition:, no_data: false, side_by_side: false, speaker: ActiveRecord::Migration.new)
          @adapter = adapter
          @name = name
          @definition = definition
          @no_data = no_data
          @side_by_side = side_by_side
          @speaker = speaker
        end

        def update
          validate_options
          dependent_views = DependentViewsFinder.new(adapter.connection, name).find
          
          return update_base_only if dependent_views.empty?

          adapter.connection.transaction do
            execute_cascade_update(dependent_views)
          end
        end

        private

        attr_reader :adapter, :name, :definition, :no_data, :side_by_side, :speaker

        def validate_options
          if side_by_side && no_data
            raise ArgumentError, "cascade with side_by_side and no_data options is not supported"
          end
        end

        def execute_cascade_update(dependents)
          dependent_state = capture_dependent_state(dependents)
          
          begin
            dependents.reverse_each { |dep| drop_dependent_view(dep) }
            update_base_view
            dependents.each { |dep| recreate_dependent_view(dep, dependent_state[dep]) }
          rescue => e
            raise Postgres::CascadeUpdateFailedError.new(name, e.message)
          end
        end

        def capture_dependent_state(dependents)
          dependents.each_with_object({}) do |view_name, state|
            view_info = find_view_info(view_name)
            indexes = find_indexes(view_name)

            state[view_name] = {
              definition: view_info.definition,
              materialized: view_info.materialized,
              indexes: indexes
            }
          end
        end

        def find_view_info(view_name)
          unqualified_name = view_name.split('.').last
          schema_name = view_name.include?('.') ? view_name.split('.').first : 'public'

          # Try to find in adapter.views first (for views in search path)
          view = adapter.views.find { |v| v.name == view_name || v.name == unqualified_name }
          return view if view

          # If not found, query directly from PostgreSQL (for views outside search path)
          result = adapter.connection.execute(<<-SQL).first
            SELECT
              pg_get_viewdef(c.oid) AS definition,
              c.relkind AS kind
            FROM pg_class c
            LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = '#{unqualified_name}'
              AND n.nspname = '#{schema_name}'
              AND c.relkind IN ('m', 'v')
          SQL

          raise("View '#{view_name}' not found in database") unless result

          Scenic::View.new(
            name: view_name,
            definition: result["definition"].strip,
            materialized: result["kind"] == "m"
          )
        end

        def find_indexes(view_name)
          unqualified_name = view_name.split('.').last
          schema_name = view_name.include?('.') ? view_name.split('.').first : 'public'

          # Try standard Indexes class first (for views in search path)
          indexes = Indexes.new(connection: adapter.connection).on(unqualified_name)
          return indexes unless indexes.empty?

          # If no indexes found, try querying specific schema
          results = adapter.connection.execute(<<-SQL)
            SELECT
              t.relname as object_name,
              i.relname as index_name,
              pg_get_indexdef(d.indexrelid) AS definition
            FROM pg_class t
            INNER JOIN pg_index d ON t.oid = d.indrelid
            INNER JOIN pg_class i ON d.indexrelid = i.oid
            LEFT JOIN pg_namespace tn ON tn.oid = t.relnamespace
            LEFT JOIN pg_namespace in_ns ON in_ns.oid = i.relnamespace
            WHERE i.relkind = 'i'
              AND d.indisprimary = 'f'
              AND t.relname = '#{unqualified_name}'
              AND tn.nspname = '#{schema_name}'
            ORDER BY i.relname
          SQL

          results.map do |result|
            Scenic::Index.new(
              object_name: result["object_name"],
              index_name: result["index_name"],
              definition: result["definition"]
            )
          end
        end

        def drop_dependent_view(view_name)
          view_info = find_view_info(view_name)

          if view_info.materialized
            adapter.drop_materialized_view(view_name)
          else
            adapter.drop_view(view_name)
          end
        end

        def update_base_view
          if side_by_side
            SideBySide.new(adapter: adapter, name: name, definition: definition, speaker: speaker).update
          else
            IndexReapplication.new(connection: adapter.connection, speaker: speaker).on(name) do
              adapter.drop_materialized_view(name)
              adapter.create_materialized_view(name, definition, no_data: no_data)
            end
          end
        end

        def recreate_dependent_view(view_name, state)
          view_type = state[:materialized] ? "materialized view" : "view"

          speaker.say "   -> Recreating dependent #{view_type} '#{view_name}'"

          if state[:materialized]
            adapter.create_materialized_view(view_name, state[:definition])
          else
            adapter.create_view(view_name, state[:definition])
          end

          IndexCreation.new(connection: adapter.connection, speaker: speaker)
                      .try_create(state[:indexes])

        end

        def update_base_only
          if side_by_side
            SideBySide.new(adapter: adapter, name: name, definition: definition, speaker: speaker).update
          else
            IndexReapplication.new(connection: adapter.connection, speaker: speaker).on(name) do
              adapter.drop_materialized_view(name)
              adapter.create_materialized_view(name, definition, no_data: no_data)
            end
          end
        end

      end
    end
  end
end