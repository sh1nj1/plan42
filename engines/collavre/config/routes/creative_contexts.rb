# frozen_string_literal: true

get :contexts
patch :update_contexts
patch :update_metadata
get :workflow
post :workflow_rule, action: :create_workflow_rule
patch :workflow_rule, action: :update_workflow_rule
