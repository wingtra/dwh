SELECT

    /*
        Internal users. res_users has no name column directly; the display
        name is resolved via partner_id -> res_partner.name.
    */

    /* IDS */
    id as user_id,
    partner_id,
    company_id,
    sale_team_id,
    action_id,
    oauth_provider_id,
    create_uid as created_by_user_id,
    write_uid as updated_by_user_id,

    /* TIMESTAMPS */
    create_date as created_at,
    write_date as updated_at,

    /* DIMENSIONS */
    login,
    active as is_active,
    share as is_share_user,
    notification_type,
    odoobot_state,
    odoobot_failed as has_odoobot_failed,
    tour_enabled as is_tour_enabled,
    property_warehouse_id as warehouse_property_raw

FROM {{ source('odoo', 'res_users') }}
