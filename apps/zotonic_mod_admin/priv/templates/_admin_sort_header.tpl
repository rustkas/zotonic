{#
    Page table sort header.

    Ascending for alphabet and numbers: A to Z, 0 to 9
    Ascending for dates: old to new. The default for dates should thus be descending.

    Ascending is identified as: 1
    Descending is identified as: -1
    Unsorted is identified as: 0

    Params:
    field: database column
    caption: display text
    type: used to distinguish type "date" to set inital sort as descending
    qsort: the sort id passed in url param qsort
#}
{% with
    "<span class='arrow up'></span>",
    "<span class='arrow down'></span>",
    qsort|default:q.qsort
    as
    up_arrow,
    down_arrow,
    qsort
%}
{% with
    (qsort == field)|if
        : 1
        : ((qsort == "-" ++ field)|if
            : (-1)
            : 0)
    as
    sort_status
%}
    {% with
        (sort_status == 0)|if
            : ((type == "date")|if
                : (-1)
                : 1)
            : (-sort_status)
        as
        next_modifier
    %}
        {% with
            (sort_status == 0)|if
                : ""
                : ((sort_status == 1)|if
                    : up_arrow
                    : down_arrow)
            as
            status_modifier_char
        %}
            {% with
                (next_modifier == 0)|if
                    : ""
                    : ((next_modifier == 1)|if
                        : ""
                        : "-")
                as
                next_modifier_param_char
            %}
                <a href="{% url zotonic_dispatch|as_atom
                                    qsort=next_modifier_param_char++field
                                    qcat=q.qcat
                                    qs=q.qs
                                    qpagelen=q.qpagelen
                                    qquery=q.qquery
                         %}{{ url_append }}">{{ caption }}{{ status_modifier_char }}</a>
            {% endwith %}
        {% endwith %}
    {% endwith %}
{% endwith %}
{% endwith %}
