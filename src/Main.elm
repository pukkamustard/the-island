module Main exposing (..)

import Return exposing (Return)
import Random.Pcg as Random
import Time exposing (Time)
import Char
import Task


--

import AnimationFrame
import Animation exposing (Animation)
import Ease
import Math.Vector2 as Vector2 exposing (Vec2, vec2, getX, getY)


--

import Html as H
import Svg as S
import Svg.Attributes as SA
import Svg.Events as SE


--

import Uuid exposing (Uuid)
import WebSocket as WS
import Json.Encode as JE
import Json.Decode as JD
import Json.Decode.Applicative as JDA


--

import Window
import Keyboard
import Mouse


main : Program Never Model Msg
main =
    H.program
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        }



-- Island


type alias Island =
    { id : Uuid
    , position : Vec2
    }


{-| Generate a random island

TODO: check that not too close to existing islands

-}
islandGenerator : List Island -> Random.Generator Island
islandGenerator islands =
    Random.map3
        (\id x y ->
            { id = id
            , position = vec2 x y
            }
        )
        Uuid.uuidGenerator
        (Random.float 0 (worldSize |> getX))
        (Random.float 0 (worldSize |> getY))


encodeIsland : Island -> JE.Value
encodeIsland island =
    JE.object
        [ ( "id", Uuid.encode island.id )
        , ( "position", encodeVec2 island.position )
        ]


islandDecoder : JD.Decoder Island
islandDecoder =
    JD.succeed Island
        |> JDA.apply (JD.field "id" Uuid.decoder)
        |> JDA.apply (JD.field "position" vec2Decoder)



-- Post


type alias Post =
    { id : Uuid
    , createdAt : Time
    , direction : Vec2
    , origin : Vec2
    , msg : String
    }


postGenerator : Time -> Vec2 -> Vec2 -> String -> Random.Generator Post
postGenerator now origin direction msg =
    Random.map
        (\id ->
            { id = id

            -- Hack to throw the bottle ahead a bit
            , createdAt = now - 5000
            , direction = direction
            , origin = origin
            , msg = msg
            }
        )
        Uuid.uuidGenerator


vec2Decoder : JD.Decoder Vec2
vec2Decoder =
    JD.succeed vec2
        |> JDA.apply (JD.field "x" JD.float)
        |> JDA.apply (JD.field "y" JD.float)


encodeVec2 : Vec2 -> JE.Value
encodeVec2 vec =
    JE.object
        [ ( "x", vec |> getX |> JE.float )
        , ( "y", vec |> getY |> JE.float )
        ]


postDecoder : JD.Decoder Post
postDecoder =
    JD.succeed Post
        |> JDA.apply (JD.field "id" Uuid.decoder)
        |> JDA.apply (JD.field "createdAt" JD.float)
        |> JDA.apply (JD.field "direction" vec2Decoder)
        |> JDA.apply (JD.field "origin" vec2Decoder)
        |> JDA.apply (JD.field "msg" JD.string)


encodePost : Post -> JE.Value
encodePost post =
    JE.object
        [ ( "id", Uuid.encode post.id )
        , ( "createdAt", JE.float post.createdAt )
        , ( "direction", encodeVec2 post.direction )
        , ( "origin", encodeVec2 post.origin )
        , ( "msg", JE.string post.msg )
        ]



-- Server communication


type ServerMsg
    = NewIsland Island
    | NewPost Post
    | Clear


serverUrl : String
serverUrl =
    "ws://localhost:9998"


encodeServerMsg : ServerMsg -> JE.Value
encodeServerMsg msg =
    case msg of
        NewIsland island ->
            JE.object
                [ ( "type", JE.string "NewIsland" )
                , ( "island", encodeIsland island )
                ]

        NewPost post ->
            JE.object
                [ ( "type", JE.string "NewPost" )
                , ( "post", encodePost post )
                ]

        Clear ->
            JE.object
                [ ( "type", JE.string "Clear" )
                ]


serverMsgDecoder : JD.Decoder ServerMsg
serverMsgDecoder =
    JD.field "type" JD.string
        |> JD.andThen
            (\type_ ->
                case type_ of
                    "NewPost" ->
                        JD.succeed NewPost
                            |> JDA.apply (JD.field "post" postDecoder)

                    "NewIsland" ->
                        JD.succeed NewIsland
                            |> JDA.apply (JD.field "island" islandDecoder)

                    _ ->
                        JD.fail "not implemented"
            )


send : ServerMsg -> Cmd msg
send msg =
    msg
        |> encodeServerMsg
        |> JE.encode 0
        |> WS.send serverUrl



-- Game View helpers


{-| Focus (or what is my view of the world)
-}
type Focus
    = World
    | OneIsland Island
    | Transitioning
        { to : Focus
        , viewConfig : Animation ViewConfig
        }


type alias ViewConfig =
    { size : Vec2
    , center : Vec2
    }


topLeft : ViewConfig -> Vec2
topLeft viewConfig =
    viewConfig.center
        |> Vector2.add (viewConfig.size |> Vector2.scale 0.5 |> Vector2.negate)


worldSize : Vec2
worldSize =
    vec2 100 100


islandWorldSize : Vec2
islandWorldSize =
    vec2 10 10


viewConfig : Time -> Focus -> ViewConfig
viewConfig now focus =
    case focus of
        World ->
            { size = worldSize
            , center = worldSize |> Vector2.scale 0.5
            }

        OneIsland island ->
            { size = islandWorldSize
            , center = island.position
            }

        Transitioning { viewConfig } ->
            Animation.animate viewConfig now


towards : Vec2 -> Vec2 -> Float -> Vec2
towards from to c =
    Vector2.add from (Vector2.sub to from |> Vector2.scale c)


transitionFocus : Model -> Focus -> Focus -> Focus
transitionFocus model current to =
    let
        now =
            model.time

        currentViewConfig =
            viewConfig model.time current

        toViewConfig =
            viewConfig model.time to
    in
        Transitioning
            { to = to
            , viewConfig =
                (\size center -> { size = size, center = center })
                    |> Animation.pure
                    |> Animation.apply
                        (Animation.animation now
                            (1 * Time.second)
                            (Ease.inOutSine >> towards currentViewConfig.size toViewConfig.size)
                        )
                    |> Animation.apply
                        (Animation.animation now
                            (1 * Time.second)
                            (Ease.inOutSine >> towards currentViewConfig.center toViewConfig.center)
                        )
            }



-- MODEL


type alias Model =
    { time : Time
    , windowSize : Window.Size

    --
    , islands : List Island
    , posts : List Post
    , focus : Focus
    }


init : Return Msg Model
init =
    { time = 0
    , windowSize = { width = 100, height = 100 }

    --
    , islands = []
    , posts = []
    , focus = World
    }
        |> Return.singleton
        |> Return.command (Window.size |> Task.perform Resize)
        |> Return.command (Time.now |> Task.perform SetTime)
        |> Return.command (islandGenerator [] |> Random.generate CreateIsland)



-- UPDATE


type Msg
    = CreateIsland Island
    | SelectIsland Island
      --
    | CreatePost Post
      --
    | KeyPress Keyboard.KeyCode
    | Click Mouse.Position
    | Resize Window.Size
    | Tick Time
    | SetTime Time
      --
    | ServerMsg (Result String ServerMsg)


update : Msg -> Model -> Return Msg Model
update msg model =
    case msg of
        CreateIsland island ->
            { model
                | islands = island :: model.islands
                , focus = transitionFocus model model.focus (OneIsland island)
            }
                |> Return.singleton
                |> Return.command (island |> NewIsland |> send)

        SelectIsland island ->
            { model
                | focus = transitionFocus model model.focus (OneIsland island)
            }
                |> Return.singleton

        Tick dt ->
            { model | time = model.time + dt }
                |> Return.singleton
                |> Return.andThen updateFocus
                |> Return.andThen dropFromTheFaceOfTheWorld

        SetTime t ->
            { model | time = t }
                |> Return.singleton

        KeyPress keyCode ->
            if keyCode == Char.toCode 'w' then
                { model | focus = transitionFocus model model.focus World }
                    |> Return.singleton
            else if keyCode == Char.toCode 'i' then
                model
                    |> Return.singleton
                    |> Return.command (islandGenerator model.islands |> Random.generate CreateIsland)
            else if keyCode == Char.toCode 'c' then
                init
                    |> Return.command (Clear |> send)
            else
                model
                    |> Return.singleton

        CreatePost post ->
            { model | posts = post :: model.posts }
                |> Return.singleton
                |> Return.command (post |> NewPost |> send)

        Click position ->
            let
                relative =
                    { x = (toFloat position.x / toFloat model.windowSize.width)
                    , y = (toFloat position.y / toFloat model.windowSize.height)
                    }

                worldPosition =
                    Vector2.add
                        (viewConfig model.time model.focus |> topLeft)
                        (vec2
                            (viewConfig model.time model.focus |> .size |> getX |> (*) relative.x)
                            (viewConfig model.time model.focus |> .size |> getY |> (*) relative.y)
                        )

                newPost =
                    case model.focus of
                        OneIsland island ->
                            { createdAt = model.time
                            , origin = island.position
                            , direction = Vector2.direction worldPosition island.position
                            , msg = "Hello!"
                            }
                                |> Just

                        _ ->
                            Nothing
            in
                model
                    |> Return.singleton
                    |> Return.command
                        (case model.focus of
                            OneIsland island ->
                                postGenerator model.time island.position (Vector2.direction worldPosition island.position) "Hello!"
                                    |> Random.generate CreatePost

                            _ ->
                                Cmd.none
                        )

        Resize size ->
            { model | windowSize = size }
                |> Return.singleton

        ServerMsg (Ok (NewPost post)) ->
            { model
                | posts =
                    if List.member post model.posts then
                        model.posts
                    else
                        (post |> Debug.log "remote post!") :: model.posts
            }
                |> Return.singleton

        ServerMsg (Ok (NewIsland island)) ->
            { model
                | islands =
                    if List.member island model.islands then
                        model.islands
                    else
                        (island) :: model.islands
            }
                |> Return.singleton

        ServerMsg (Ok Clear) ->
            init

        ServerMsg (Err msg) ->
            let
                msg_ =
                    msg |> Debug.log "ServerMsg decoding failed"
            in
                model
                    |> Return.singleton


updateFocus : Model -> Return Msg Model
updateFocus model =
    case model.focus of
        Transitioning { to, viewConfig } ->
            if Animation.isDone viewConfig model.time then
                { model | focus = to }
                    |> Return.singleton
            else
                model
                    |> Return.singleton

        _ ->
            model
                |> Return.singleton


dropFromTheFaceOfTheWorld : Model -> Return Msg Model
dropFromTheFaceOfTheWorld model =
    { model
        | posts =
            model.posts
                |> List.filter (\post -> model.time - post.createdAt <= 2 * Time.minute)
    }
        |> Return.singleton



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    [ AnimationFrame.diffs Tick
    , Keyboard.presses KeyPress
    , Mouse.clicks Click
    , Window.resizes Resize
    , WS.listen serverUrl (JD.decodeString serverMsgDecoder >> ServerMsg)
    ]
        |> Sub.batch



-- VIEW


{-| Helper to computer viewBox from center and size of screen
-}
viewBoxHelper : ViewConfig -> String
viewBoxHelper viewConfig =
    (viewConfig |> topLeft |> getX |> toString)
        ++ " "
        ++ (viewConfig |> topLeft |> getY |> toString)
        ++ " "
        ++ (viewConfig.size |> getX |> toString)
        ++ " "
        ++ (viewConfig.size |> getY |> toString)


view : Model -> H.Html Msg
view model =
    S.svg
        [ SA.width "100vw"
        , SA.height "100vh"
        , SA.display "block"
        , model.focus
            |> viewConfig model.time
            |> viewBoxHelper
            |> SA.viewBox
        ]
        ([ preloadAssets
         , [ background ]
         , case model.focus of
            OneIsland island ->
                model.islands
                    |> List.filter (.id >> (==) island.id)
                    |> List.map (drawIsland model.time model.focus)

            _ ->
                model.islands
                    |> List.map (drawIsland model.time model.focus)
         , model.posts
            |> List.map (drawPost model.time)
         ]
            |> List.concat
        )


preloadAssets : List (S.Svg Msg)
preloadAssets =
    let
        image path id =
            S.image [ SA.xlinkHref path, SA.id id ]
                []
    in
        [ image "assets/island_01_01.png" "island01"
        , image "assets/island_01_02.png" "island02"
        , image "assets/island_01_03.png" "island03"
        , image "assets/island_01_02.png" "island04"

        --, image "assets/island_01_waterGradient.png" "waterGradient"
        ]


background : S.Svg Msg
background =
    S.image
        [ SA.xlinkHref "assets/BackGroundBlue.png"
        , SA.x "-1000"
        , SA.y "-1000"
        , SA.height "2000"
        , SA.width "2000"
        ]
        []


drawPost : Time -> Post -> S.Svg Msg
drawPost now post =
    let
        speed =
            0.0005

        position =
            post.origin
                |> Vector2.add
                    (post.direction
                        |> Vector2.scale (speed * (now - post.createdAt))
                    )

        size =
            0.5
    in
        S.g []
            [ S.image
                [ SA.xlinkHref "assets/bottle_01.png"
                , SA.x (position |> getX |> (+) (-size / 2) |> toString)
                , SA.y (position |> getY |> (+) (-size / 2) |> toString)
                , SA.height (size |> toString)
                , SA.width (size |> toString)
                ]
                []
            ]


drawIsland : Time -> Focus -> Island -> S.Svg Msg
drawIsland now focus island =
    let
        topLeft =
            Vector2.sub
                island.position
                (islandWorldSize |> Vector2.scale 0.5)

        overlayAttributes =
            [ SA.x (topLeft |> getX |> toString)
            , SA.y (topLeft |> getY |> toString)
            , SA.height (islandWorldSize |> getX |> toString)
            , SA.width (islandWorldSize |> getY |> toString)
            ]

        image path content =
            S.image
                ([ SA.xlinkHref path ] ++ overlayAttributes)
                content

        islandAnimation =
            S.g []
                [ image "assets/island_01_01.png"
                    [ S.animate
                        [ SA.attributeName "visibility"
                        , SA.keyTimes "0;0.25"
                        , SA.values "visible;hidden"
                        , SA.calcMode "discrete"
                        , SA.dur "1s"
                        , SA.repeatCount "indefinite"
                        ]
                        []
                    ]
                , image "assets/island_01_02.png"
                    [ S.animate
                        [ SA.attributeName "visibility"
                        , SA.keyTimes "0;0.25;0.5"
                        , SA.values "hidden;visible;hidden"
                        , SA.calcMode "discrete"
                        , SA.dur "1s"
                        , SA.repeatCount "indefinite"
                        ]
                        []
                    ]
                , image "assets/island_01_03.png"
                    [ S.animate
                        [ SA.attributeName "visibility"
                        , SA.keyTimes "0;0.5;0.75"
                        , SA.values "hidden;visible;hidden"
                        , SA.calcMode "discrete"
                        , SA.dur "1s"
                        , SA.repeatCount "indefinite"
                        ]
                        []
                    ]
                , image "assets/island_01_04.png"
                    [ S.animate
                        [ SA.attributeName "visibility"
                        , SA.keyTimes "0;0.75;1"
                        , SA.values "hidden;visible;hidden"
                        , SA.calcMode "discrete"
                        , SA.dur "1s"
                        , SA.repeatCount "indefinite"
                        ]
                        []
                    ]
                ]
    in
        S.g
            [ case focus of
                World ->
                    SE.onClick (SelectIsland island)

                _ ->
                    SA.visibility "true"
            ]
            [ islandAnimation
            , image "assets/character_01.png" []
            , image "assets/palmTree_01_01.png" []
            ]
