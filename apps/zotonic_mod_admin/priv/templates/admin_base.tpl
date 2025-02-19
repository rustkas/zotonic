<!DOCTYPE html>
<html {% include "_language_attrs.tpl" class=false %} class="zotonic-admin environment-{{ m.site.environment }}">
    <head>
        <meta charset="utf-8">
        <title>{% block title %}{_ Admin _}{% endblock %} &mdash; {{ m.site.title|default:"Zotonic" }} Admin</title>

        <link rel="icon" href="/favicon.ico" type="image/x-icon">
        <link rel="shortcut icon" href="/favicon.ico" type="image/x-icon">

        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <meta name="description" content="">

        {% lib
            "css/admin-bootstrap3.css"
            minify
        %}

        {% lib
            "css/zp-menuedit.css"
            "css/z.modal.css"
            "css/z.icons.css"
            "css/z.bridge.css"
            "css/logon.css"
            "css/jquery.loadmask.css"
            "css/zotonic-admin.css"
            "css/zotonic-search-view-admin.css"
            minify
        %}

        {% all include "_html_head.tpl" %}
        {% all include "_html_head_admin.tpl" %}

        <!-- Le HTML5 shim, for IE6-8 support of HTML5 elements -->
        <!--[if lt IE 9]>
            <script src="http://html5shim.googlecode.com/svn/trunk/html5.js"></script>
        <![endif]-->

        {% block head_extra %}
        {% endblock %}
    </head>
    <body id="body" class="{% block bodyclass %}{% endblock %}"{% block bodyattr %}{% endblock %}>

    {% block navigation %}
        {% include "_admin_menu.tpl" %}
    {% endblock %}

    <div class="admin-container">
        {% block content %}{% endblock %}
    </div>

    {% include "_admin_footer.tpl" %}
    {% include "_bridge_warning.tpl" %}

    {% include "_admin_js_include.tpl" %}
    {% block js_extra %}{% endblock %}

    {% block html_body_admin %}{% all include "_html_body_admin.tpl" %}{% endblock %}

    {% block editor %}{% endblock %}

    {% script %}

    {% optional include "_fileuploader_worker.tpl" %}

</body>
</html>
